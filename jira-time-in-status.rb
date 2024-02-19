require 'faraday'
require 'json'
require 'time'
require 'csv'
require 'byebug'

CycleTimeIssueTypes = [
  'production defect',
  'spike',
  'story',
  'task',
]

CycleTimeIgnoredIssueTypes = [
  'bug',
  'epic',
  'initiative',
  'sub-task',
]

raise("Overlapping issue types: #{(CycleTimeIssueTypes & CycleTimeIgnoredIssueTypes).join(', ')}") if (CycleTimeIssueTypes & CycleTimeIgnoredIssueTypes).any?

AllIssueTypes = CycleTimeIssueTypes + CycleTimeIgnoredIssueTypes

CycleTimeTerminalIssueStatuses = [
  'code merged',
  'completed',
  'deployed',
  'deployed/completed',
  'done',
  'merged',
]

CycleTimeNotTerminalIssueStatuses = [
  'abandoned in development',
  'assigned for work',
  'assigned to domain team',
  'backlog',
  'bi discovery',
  'canceled',
  'cancelled',
  'code review',
  'discovery',
  'gathering requirements',
  'in dev test',
  'in progress',
  'in review',
  'in test',
  'in validation',
  'investigations',
  'on-hold',
  'open',
  'product backlog',
  'ready for execution',
  'ready for external share',
  'ready for qe',
  'ready for test',
  'ready for test/ review complet',
  'ready to begin',
  'ready to review',
  'review',
  'rework',
  'stale/abandoned',
  'test done',
  'tickets ready for team',
  'to do',
  'to test',
  'triage',
  'up next',
  'waiting for approval',
  'waiting for support',
  'work requests',
]

raise("Overlapping terminal issue statuses: #{(CycleTimeTerminalIssueStatuses & CycleTimeNotTerminalIssueStatuses).join(', ')}") if (CycleTimeTerminalIssueStatuses & CycleTimeNotTerminalIssueStatuses).any?

AllIssueStatuses = CycleTimeTerminalIssueStatuses + CycleTimeNotTerminalIssueStatuses

CycleTimeInFlightIssueStatuses = [
  'code review',
  'in dev test',
  'in progress',
  'in review',
  'in test',
  'in validation',
  'ready to review',
  'ready for qe',
  'ready for test',
  'ready for test/ review complet',
  'rework',
  'review',
  'test done',
  'to test',
]

CycleTimeNotInFlightIssueStatuses = [
  'abandoned in development',
  'assigned for work',
  'assigned to domain team',
  'backlog',
  'bi discovery',
  'canceled',
  'cancelled',
  'code merged',
  'completed',
  'deployed',
  'deployed/completed',
  'discovery',
  'done',
  'gathering requirements',
  'investigations',
  'merged',
  'on-hold',
  'open',
  'product backlog',
  'ready for execution',
  'ready for external share',
  'ready to begin',
  'stale/abandoned',
  'tickets ready for team',
  'to do',
  'triage',
  'up next',
  'waiting for approval',
  'waiting for support',
  'work requests',
]

raise("Overlapping in-flight issue statuses: #{(CycleTimeInFlightIssueStatuses & CycleTimeNotInFlightIssueStatuses).join(', ')}") if (CycleTimeInFlightIssueStatuses & CycleTimeNotInFlightIssueStatuses).any?

# puts (AllIssueStatuses - (CycleTimeInFlightIssueStatuses + CycleTimeNotInFlightIssueStatuses)).join(', ')
# puts ((CycleTimeInFlightIssueStatuses + CycleTimeNotInFlightIssueStatuses) - AllIssueStatuses).join(', ')
raise('Inconsistent terminal issue statuses vs in-flight issue statuses') if (AllIssueStatuses - (CycleTimeInFlightIssueStatuses + CycleTimeNotInFlightIssueStatuses)).any? || ((CycleTimeInFlightIssueStatuses + CycleTimeNotInFlightIssueStatuses) - AllIssueStatuses).any?

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

    all_issues.each do |issue|
      issue_id = issue.fetch('id')
      issue_key = issue.fetch('key')

      sprint_id = issue_id_to_sprint_id.fetch(issue_id)
      sprint = sprints_by_id.fetch(sprint_id)
      sprint_name = sprint.fetch('name')

      board_id = sprint.fetch('originBoardId')
      board = boards_by_id[board_id]

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
        sprint.fetch('createdDate'),
        sprint.fetch('completeDate'),
        sprint.fetch('startDate'),
        sprint.fetch('endDate'),

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
      'in_flight_hours_p50',
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
    end.each do |project_name, rows|
      data_points = rows.map do |row|
        row.fetch('in_flight_hours').to_f
      end.sort

      earliest_sprint_start_date = rows.map do |row|
        Time.parse(row.fetch('sprint_start_date'))
      end.min

      latest_sprint_end_date = rows.map do |row|
        Time.parse(row.fetch('sprint_end_date'))
      end.max

      in_flight_hours_p85 = data_points[((data_points.size * 0.85).round - 1).to_i]
      in_flight_hours_n = data_points.size
      in_flight_hours_avg = (data_points.sum / data_points.size).round(2)
      in_flight_hours_p50 = data_points[((data_points.size * 0.5).round - 1).to_i]
      in_flight_hours_min = data_points.min
      in_flight_hours_max = data_points.max

      csv << [
        project_name,

        in_flight_hours_p85,

        earliest_sprint_start_date,
        latest_sprint_end_date,

        in_flight_hours_n,
        in_flight_hours_avg,
        in_flight_hours_p50,
        in_flight_hours_min,
        in_flight_hours_max,
      ]
    end
  end
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

def issue_id_to_sprint_id
  @_issue_id_to_sprint_id ||= {}
end

def all_issues
  @_all_issues ||= sprints_in_scope.reduce({}) do |ids_to_issues, sprint|
    make_request(endpoint: "/rest/agile/1.0/sprint/#{sprint.fetch('id')}/issue?expand=changelog", paginate_through_all: true, values_key: 'issues').each do |issue|
      issue_id_to_sprint_id[issue.fetch('id')] = sprint.fetch('id') # so we can reference back the other way
      ids_to_issues[issue.fetch('id')] = issue # enforce deduplication across sprints
    end

    ids_to_issues
  end.values.sort_by do |issue|
    issue.fetch('id').to_i
  end.tap do |issues|
    puts "Found #{issues.size} issues"
    # puts issues.first.to_json

    issues.group_by do |issue|
      issue.fetch('id')
    end.select do |issue_id, issues|
      issues.size > 1
    end.tap do |dupes|
      raise("Found duplicate issues: #{dupes.keys.sort}") if dupes.keys.size > 0
    end
  end
end

def issues_by_id
  @_issues_by_id ||= all_issues.map do |issue|
    [issue.fetch('id'), issue]
  end.to_h
end

def sprints_in_scope
  all_sprints.select do |sprint|
    closed = sprint.fetch('state') == 'closed'

    end_date = nil
    if closed
      end_date = Time.parse(sprint.fetch('endDate'))
    end

    closed && end_date < Time.now && end_date >= (Time.now - four_weeks)
  end.tap do |sprints|
    puts "Using #{sprints.size} of #{all_sprints.size} after selecting for state and end dates"

    earliest_start_date = sprints.map{|s| Time.parse(s.fetch('startDate'))}.min
    latest_start_date = sprints.map{|s| Time.parse(s.fetch('startDate'))}.max

    earliest_end_date = sprints.map{|s| Time.parse(s.fetch('endDate'))}.min
    latest_end_date = sprints.map{|s| Time.parse(s.fetch('endDate'))}.max

    puts "Earliest sprint start date: #{earliest_start_date}"
    puts "Latest sprint start date: #{latest_start_date}"
    puts "Earliest sprint end date: #{earliest_end_date}"
    puts "Latest sprint end date: #{latest_end_date}"
  end
end

def four_weeks
  60 * 60 * 24 * 7 * 4
end

def all_sprints
  @_all_sprints ||= all_boards.reduce([]) do |sum, board|
    sum + get_sprints(board: board)
  end.sort_by do |sprint|
    sprint.fetch('id')
  end.tap do |sprints|
    puts "Found #{sprints.size} sprints"
    # puts sprints.first.to_json
    # puts sprints.to_json
  end
end

def get_sprints(board:)
  board_type = board.fetch('type')
  if ['kanban','simple',].include?(board_type)
    return []
  elsif ['scrum',].include?(board_type)
    return make_request(endpoint: "/rest/agile/1.0/board/#{board.fetch('id')}/sprint", paginate_through_all: true)
  else
    raise("Unknown board type: #{board_type}")
  end
end

def sprints_by_id
  @_sprints_by_id ||= all_sprints.map do |sprint|
    [sprint.fetch('id'), sprint]
  end.to_h
end

def boards_by_id
  @_boards_by_id ||= all_boards.map do |board|
    [board.fetch('id'), board]
  end.to_h
end

def all_boards
  @_all_boards ||= make_request(endpoint: '/rest/agile/1.0/board', paginate_through_all: true).sort_by do |board|
    board.fetch('id')
  end.tap do |boards|
    puts "Found #{boards.size} boards"
    # puts boards.first.to_json
  end
end

def make_request(endpoint:, paginate_through_all: false, values_key: 'values')
  original_endpoint = endpoint

  start_at = 0
  all_paginated = []

  while true
    request_endpoint = original_endpoint

    if paginate_through_all
      if request_endpoint.include?('?')
        request_endpoint += '&'
      else
        request_endpoint += '?'
      end

      request_endpoint += "startAt=#{start_at}"
    end

    puts "Requesting endpoint: #{request_endpoint}"
    response = faraday_connection.get(request_endpoint)

    raise response.body unless response.success?

    if paginate_through_all
      json = JSON.parse(response.body)

      puts response.body unless json.key?(values_key)

      all_paginated += json.fetch(values_key)

      reached_end = if json.key?('isLast')
        json.fetch('isLast')
      else
        json.fetch('startAt') + json.fetch('maxResults') >= json.fetch('total')
      end

      break if reached_end

      start_at = all_paginated.size
    else
      break
    end
  end

  return paginate_through_all ? all_paginated : JSON.parse(response.body)
end

def faraday_connection
  @_faraday_connection ||= Faraday.new(
    url: 'https://kininsurance.atlassian.net',
    headers: {
      'Authorization' => "Basic #{jira_base64_auth}",
      'Content-Type' => 'application/json'
    }
  )
end

def jira_base64_auth
  @_jira_base64_auth ||= File.read('.jira-base64-auth')
end

main
