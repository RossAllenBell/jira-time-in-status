MaxRequestThreads = 10

def issue_id_to_sprint_id
  @_issue_id_to_sprint_id ||= {}
end

def issue_id_to_board_id
  @_issue_id_to_board_id ||= {}
end

def all_issues
  @_all_issues ||= begin
    all_scrum_issues +
    all_kanban_and_simple_issues
  end.reduce({}) do |hash, issue|
    hash[issue.fetch('id')] = issue
    hash
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

def all_scrum_issues
  @_all_scrum_issues ||= split_across_workers(sprints_in_scope) do |sprint|
    make_request(endpoint: "/rest/agile/1.0/sprint/#{sprint.fetch('id')}/issue?expand=changelog", paginate_through_all: true, values_key: 'issues').each do |issue|
      issue_id_to_sprint_id[issue.fetch('id')] = sprint.fetch('id') # so we can reference back the other way
      issue_id_to_board_id[issue.fetch('id')] = sprint.fetch('originBoardId') # so we can reference back the other way
    end
  end.reduce({}) do |hash, issue|
    hash[issue.fetch('id')] = issue
    hash
  end.values.sort_by do |issue|
    issue.fetch('id').to_i
  end.tap do |issues|
    puts "Found #{issues.size} scrum issues"
    # puts issues.first.to_json

    issues.group_by do |issue|
      issue.fetch('id')
    end.select do |issue_id, issues|
      issues.size > 1
    end.tap do |dupes|
      raise("Found duplicate scrum issues: #{dupes.keys.sort}") if dupes.keys.size > 0
    end
  end
end

def all_kanban_and_simple_issues
  @all_kanban_and_simple_issues ||= begin
    start_date = median_sprint_start_date.strftime('%Y-%m-%d')
    end_date = median_sprint_end_date.strftime('%Y-%m-%d')

    split_across_workers(kanban_and_simple_project_boards) do |kanban_and_simple_board|
      # puts kanban_and_simple_board.to_json
      jql = URI.encode_www_form_component("project = \"#{kanban_and_simple_board.fetch('location').fetch('projectKey')}\" AND resolved > \"#{start_date}\" AND resolved <= \"#{end_date}\" ORDER BY id")
      make_request(endpoint: "/rest/api/3/search?expand=changelog&jql=#{jql}", paginate_through_all: true, values_key: 'issues').each do |issue|
        issue_id_to_board_id[issue.fetch('id')] = kanban_and_simple_board.fetch('id') # so we can reference back the other way
      end
    end
  end.reduce({}) do |hash, issue|
    hash[issue.fetch('id')] = issue
    hash
  end.values.sort_by do |issue|
    issue.fetch('id').to_i
  end.tap do |issues|
    puts "Found #{issues.size} kanban_and_simple issues"
    # puts issues.first(10).to_json

    issues.group_by do |issue|
      issue.fetch('id')
    end.select do |issue_id, issues|
      issues.size > 1
    end.tap do |dupes|
      raise("Found duplicate kanban and simple issues: #{dupes.keys.sort}") if dupes.keys.size > 0
    end
  end
end

def kanban_and_simple_project_boards
  @_kanban_and_simple_project_boards ||= all_boards.select do |board|
    board_type = board.fetch('type')
    board.dig('location', 'projectKey') && ['kanban','simple',].include?(board_type)
  end.tap do |boards|
    puts "Found #{boards.size} kanban and simple boards"
    # puts boards.to_json
  end
end

def issues_by_id
  @_issues_by_id ||= all_issues.map do |issue|
    [issue.fetch('id'), issue]
  end.to_h
end

def sprints_in_scope
  @_sprints_in_scope ||= all_sprints.select do |sprint|
    closed = sprint.fetch('state') == 'closed'

    end_date = nil
    if closed
      end_date = Time.parse(sprint.fetch('endDate'))
    end

    closed && end_date < Time.now && end_date >= (Time.now - four_weeks_in_seconds)
  end.tap do |sprints|
    puts "Using #{sprints.size} of #{all_sprints.size} after selecting for start and end dates"

    earliest_start_date = sprints.map{|s| Time.parse(s.fetch('startDate'))}.min
    latest_start_date = sprints.map{|s| Time.parse(s.fetch('startDate'))}.max

    earliest_end_date = sprints.map{|s| Time.parse(s.fetch('endDate'))}.min
    latest_end_date = sprints.map{|s| Time.parse(s.fetch('endDate'))}.max

    puts "Earliest sprint start date: #{earliest_start_date}"
    puts "Latest sprint start date: #{latest_start_date}"
    puts ''
    puts "Earliest sprint end date: #{earliest_end_date}"
    puts "Latest sprint end date: #{latest_end_date}"

    # puts sprints.map{ |s| s.fetch('id').to_i}.to_json
  end
end

def median_sprint_start_date
  @_median_sprint_start_date ||= sprints_in_scope.map do |sprint|
    Time.parse(sprint.fetch('startDate'))
  end.sort[(sprints_in_scope.size * 0.25).ceil].tap do |start_date|
    puts "Using median sprint start date of: #{start_date}"
  end
end

def median_sprint_end_date
  @_median_sprint_end_date ||= sprints_in_scope.map do |sprint|
    Time.parse(sprint.fetch('endDate'))
  end.sort[(sprints_in_scope.size * 0.75).ceil].tap do |end_date|
    puts "Using median sprint end date of: #{end_date}"
  end
end

def four_weeks_in_seconds
  60 * 60 * 24 * 7 * 4
end

def all_sprints
  @_all_sprints ||= split_across_workers(all_boards) do |board|
    get_sprints(board: board)
  end.reduce({}) do |hash, sprint|
    hash[sprint.fetch('id')] = sprint
    hash
  end.values.sort_by do |sprint|
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
    # if board.fetch('id') == 959
    #   puts board.to_json
    #   raise
    # end
    board.fetch('id')
  end.tap do |boards|
    puts "Found #{boards.size} boards"
    # puts boards.to_json
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

    if !response.success?
      if response.body.include?('Client must be authenticated')
        puts "Received an error that implies either your auth token is not set, is not valid, or your Jira user doesn't have the permissions necessary to fetch sprint boards, which is a permission not given to users by default."
        puts "Try this as a faster test:"
        puts "\tcurl  -X GET -H \"Authorization: Basic PUT_YOUR_TOKEN_HERE\" -H \"Content-Type: application/json\" https://kininsurance.atlassian.net/rest/agile/1.0/board\""
      end

      raise response.body
    end

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

def split_across_workers(payloads, &block)
  payloads_to_iterate = payloads.dup # leave original list intact
  return_values = Queue.new
  threads = []
  while payloads_to_iterate.size + threads.size > 0
    threads.each_with_index do |thread, index|
      if !thread.status
        threads[index] = nil
        thread.join
      end
    end
    threads.compact!
    while threads.size < MaxRequestThreads && payloads_to_iterate.size > 0
      threads << Thread.new(payloads_to_iterate.shift) do |payload|
        block.call(payload).each do |return_value|
          return_values << return_value
        end
      end
    end
    sleep 0.01
  end
  Array.new(return_values.size) { return_values.pop }
end
