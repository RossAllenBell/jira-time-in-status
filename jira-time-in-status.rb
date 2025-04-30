require 'faraday'
require 'json'
require 'time'
require 'csv'
require 'byebug'

Dir['./lib/*'].each { |file| require file }

def main
  issues_to_time_sums = {}

  statuses_from_changelog = Set.new

  all_issues.each do |issue|
    issue_id = issue.fetch('id')
    issues_to_time_sums[issue_id] = {}

    changelog = if issue.dig('changelog', 'maxResults') == issue.dig('changelog', 'total')
      issue.dig('changelog', 'histories')
    else
      make_request(endpoint: "/rest/api/3/issue/#{issue_id}/changelog", paginate_through_all: true)
    end

    last_change_start = Time.parse(issue.fetch('fields').fetch('created'))

    changelog.select do |change|
      change.fetch('items').detect do |item|
        item.fetch('field') == 'status'
      end
    end.sort_by do |change|
      Time.parse(change.fetch('created'))
    end.each do |change|
      items = change.fetch('items').select do |item|
        is_field = item['field'] == 'status'
        is_field_id = item['fieldId'] == 'status'
        is_field_type = item['fieldtype'] == 'jira'
        is_field && is_field_id && is_field_type
      end

      raise if items.size > 1

      item = items.first
      created = Time.parse(change.fetch('created'))

      from_change = item.fetch('fromString')
      to_change = item.fetch('toString')

      statuses_from_changelog.add(from_change)
      statuses_from_changelog.add(to_change)

      issues_to_time_sums[issue_id][from_change] ||= 0
      issues_to_time_sums[issue_id][from_change] += created - last_change_start

      last_change_start = created
    end
  end

  timestamp = Time.now.to_i
  filename_raw = "output/jira-time-in-status-raw-#{timestamp}.csv"
  filename_summarized = "output/jira-time-in-status-summarized-#{timestamp}.csv"

  puts "Writing raw data to: #{filename_raw}"

  CSV.open(filename_raw, 'w') do |csv|
    csv << [
      'board_id',
      'project_name',

      'sprint_id',
      'sprint_name',
      'sprint_created_date',
      'sprint_complete_date',
      'sprint_start_date',
      'sprint_end_date',

      'issue_id',
      'issue_key',
      'issue_created',
      'epic_key',
      'issue_type',
      'issue_status',

      'is_cycle_time_task',
      'is_cycle_time_status',
      'is_cycle_time_data',

      'in_flight_hours',
      'raw_sums_payload',
    ]

    all_found_issue_types = all_issues.map do |issue|
      issue.dig('fields', 'issuetype', 'name') || raise(issue.to_json)
    end.uniq.map(&:downcase).sort
    (all_found_issue_types - AllIssueTypes).tap do |unexpected_issue_types|
      raise "Unexpected issue types: #{unexpected_issue_types.join(', ')}" if unexpected_issue_types.any?
    end

    all_found_issue_statuses = (all_issues.map do |issue|
      issue.dig('fields', 'status', 'name') || raise(issue.to_json)
    end + statuses_from_changelog.to_a).map(&:downcase).uniq.sort
    (all_found_issue_statuses - AllIssueStatuses).tap do |unexpected_issue_statuses|
      raise "Unexpected issue statuses: #{unexpected_issue_statuses.join(', ')}" if unexpected_issue_statuses.any?
    end

    all_issues.sort_by do |issue|
      issue_id = issue.fetch('id')

      sprint_id = issue_id_to_sprint_id[issue_id]
      sprint = sprints_by_id.fetch(sprint_id) unless sprint_id.nil?

      board_id = issue_id_to_board_id[issue_id]
      board = boards_by_id.fetch(board_id) unless board_id.nil?

      project_name = board&.dig('location', 'projectName')

      [project_name, board_id || 0, sprint_id || 0, issue_id]
    end.each do |issue|
      issue_id = issue.fetch('id')
      issue_key = issue.fetch('key')

      sprint_id = issue_id_to_sprint_id[issue_id]
      sprint = sprints_by_id.fetch(sprint_id) unless sprint_id.nil?
      sprint_name = sprint.fetch('name') unless sprint_id.nil?

      board_id = issue_id_to_board_id[issue_id]
      board = boards_by_id.fetch(board_id) unless board_id.nil?

      if board.nil?
        missing_board = {
          board_id: board_id,
          sprint_id: sprint_id,
          sprint_name: sprint_name,
          issue_id: issue_id,
          issue_key: issue_key,
        }
        puts "WARN, missing board: #{missing_board.to_json}"
      end

      project_name = board&.dig('location', 'projectName')

      issue_type = issue.dig('fields', 'issuetype', 'name') || raise(issue.to_json)
      issue_status = issue.dig('fields', 'status', 'name') || raise(issue.to_json)

      time_sums = issues_to_time_sums.fetch(issue_id)

      in_flight_seconds = time_sums.select do |status, seconds|
        is_status_in_flight(status)
      end.values.sum
      in_flight_hours = (in_flight_seconds / 60 / 60).round(2)
      raw_sums_payload = time_sums.to_json

      csv << [
        board_id,
        project_name,

        sprint_id,
        sprint_name,
        sprint&.fetch('createdDate'),
        sprint&.fetch('completeDate'),
        sprint&.fetch('startDate'),
        sprint&.fetch('endDate'),

        issue_id,
        issue_key,
        issue.dig('fields', 'created') || raise(issue.to_json),
        issue.dig('fields', 'epic', 'key'),
        issue_type,
        issue_status,

        is_cycle_time_task(issue_type),
        is_cycle_time_status(issue_status),
        is_cycle_time_data(in_flight_hours),

        in_flight_hours,
        raw_sums_payload,
      ]
    end
  end

  puts "Reading raw data back from #{filename_raw}"

  raw_data = CSV.read(filename_raw, headers: true)

  puts "Writing summarized data to: #{filename_summarized}"

  CSV.open(filename_summarized, 'w') do |csv|
    csv << [
      'project_name',

      'in_flight_hours_p85',

      'earliest_sprint_start_date',
      'latest_sprint_end_date',

      'in_flight_hours_n',
      'in_flight_hours_avg',
      'in_flight_hours_p75',
      'in_flight_hours_p50',
      'in_flight_hours_p25',
      'in_flight_hours_min',
      'in_flight_hours_max',
    ]

    raw_data.map(&:to_h).select do |row|
      is_cycle_time_task = row.fetch('is_cycle_time_task') == 'true'
      is_cycle_time_status = row.fetch('is_cycle_time_status') == 'true'
      is_cycle_time_data = row.fetch('is_cycle_time_data') == 'true'

      is_cycle_time_task && is_cycle_time_status && is_cycle_time_data
    end.group_by do |row|
      row.fetch('project_name')
    end.to_a.sort_by(&:first).to_h.each do |project_name, rows|
      data_points = rows.map do |row|
        row.fetch('in_flight_hours').to_f
      end.sort

      earliest_sprint_start_date = rows.map do |row|
        Time.parse(row.fetch('sprint_start_date')) unless row.fetch('sprint_start_date').to_s.size == 0
      end.compact.min

      latest_sprint_end_date = rows.map do |row|
        Time.parse(row.fetch('sprint_end_date')) unless row.fetch('sprint_end_date').to_s.size == 0
      end.compact.max

      in_flight_hours_p85 = data_points[((data_points.size * 0.85).round - 1).to_i]
      in_flight_hours_n = data_points.size
      in_flight_hours_avg = (data_points.sum / data_points.size).round(2)
      in_flight_hours_p75 = data_points[((data_points.size * 0.75).round - 1).to_i]
      in_flight_hours_p50 = data_points[((data_points.size * 0.5).round - 1).to_i]
      in_flight_hours_p25 = data_points[((data_points.size * 0.25).round - 1).to_i]
      in_flight_hours_min = data_points.min
      in_flight_hours_max = data_points.max

      csv << [
        project_name,

        in_flight_hours_p85,

        earliest_sprint_start_date,
        latest_sprint_end_date,

        in_flight_hours_n,
        in_flight_hours_avg,
        in_flight_hours_p75,
        in_flight_hours_p50,
        in_flight_hours_p25,
        in_flight_hours_min,
        in_flight_hours_max,
      ]
    end
  end

  puts "Reading summarized data back from #{filename_summarized}"
  summarized_data = CSV.read(filename_summarized, headers: true)

  summarized_data = summarized_data.select do |row|
    row.fetch('in_flight_hours_n').to_i >= MinimumNForSummaryOutput
  end.sort_by do |row|
    row.fetch('in_flight_hours_p85').to_f
  end

  summary_message = <<~HEREDOC
    Shout out to the three teams with the shortest sprint/kanban task in-flight cycle times (p85, n >= 10) for the past two completed sprint windows:
    #{summarized_data[0].fetch('project_name')}: #{summarized_data[0].fetch('in_flight_hours_p85').to_f.round.to_i}hrs :fire:
    #{summarized_data[1].fetch('project_name')}: #{summarized_data[1].fetch('in_flight_hours_p85').to_f.round.to_i}hrs
    #{summarized_data[2].fetch('project_name')}: #{summarized_data[2].fetch('in_flight_hours_p85').to_f.round.to_i}hrs

    Source: https://github.com/RossAllenBell/jira-time-in-status
  HEREDOC

  puts ''
  puts summary_message
end

def is_cycle_time_task(issue_type)
  issue_type_downcase = issue_type.downcase

  return true if CycleTimeIssueTypes.include?(issue_type_downcase)

  return false if CycleTimeIgnoredIssueTypes.include?(issue_type_downcase)

  raise("Unexpected issue type: #{issue_type_downcase}")
end

def is_cycle_time_status(status)
  status_downcase = status.downcase

  return true if CycleTimeTerminalIssueStatuses.include?(status_downcase)

  return false if CycleTimeNotTerminalIssueStatuses.include?(status_downcase)

  raise("Unexpected status: #{status_downcase}")
end

def is_cycle_time_data(in_flight_hours)
  return in_flight_hours > 0
end

def is_status_in_flight(status)
  status_downcase = status.downcase

  return true if CycleTimeInFlightIssueStatuses.include?(status_downcase)

  return false if CycleTimeNotInFlightIssueStatuses.include?(status_downcase)

  raise("Unexpected status: #{status_downcase}")
end

main
