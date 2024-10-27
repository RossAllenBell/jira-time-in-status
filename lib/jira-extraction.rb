MaxRequestThreads = 10

def issue_id_to_sprint_id
  @_issue_id_to_sprint_id ||= {}
end

def all_issues
  @_all_issues ||= begin
    sprints_to_iterate = sprints_in_scope.dup # leave original list intact
    ids_to_issues = {}
    threads = []
    while sprints_to_iterate.size + threads.size > 0
      threads.each_with_index do |thread, index|
        if !thread.status
          threads[index] = nil
          thread.join
        end
      end
      threads.compact!
      while threads.size < MaxRequestThreads && sprints_to_iterate.size > 0
        threads << Thread.new(sprints_to_iterate.shift) do |sprint|
          make_request(endpoint: "/rest/agile/1.0/sprint/#{sprint.fetch('id')}/issue?expand=changelog", paginate_through_all: true, values_key: 'issues').each do |issue|
            issue_id_to_sprint_id[issue.fetch('id')] = sprint.fetch('id') # so we can reference back the other way
            ids_to_issues[issue.fetch('id')] = issue # enforce deduplication across sprints
          end
        end
      end
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
  @_all_sprints ||= begin
    boards_to_iterate = all_boards.dup # leave original list intact
    sprints = []
    threads = []
    while boards_to_iterate.size + threads.size > 0
      threads.each_with_index do |thread, index|
        if !thread.status
          threads[index] = nil
          thread.join
        end
      end
      threads.compact!
      while threads.size < MaxRequestThreads && boards_to_iterate.size > 0
        threads << Thread.new(boards_to_iterate.shift) do |board|
          sprints += get_sprints(board: board)
        end
      end
    end
    sprints
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