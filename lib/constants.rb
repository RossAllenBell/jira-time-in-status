MinimumNForSummaryOutput = 10

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
  'portfolio',
  'sub-task',
  'vulnerability',
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
  'pending production deployment'
]

CycleTimeNotTerminalIssueStatuses = [
  'abandoned',
  'abandoned in development',
  'assigned',
  'assigned for work',
  'assigned to domain team',
  'backlog',
  'bi discovery',
  'canceled',
  'cancelled',
  'code review',
  'discovery',
  'engineer testing',
  'gathering requirements',
  'hold',
  'in dev test',
  'in progress',
  'in review',
  'in test',
  'in validation',
  'investigations',
  'new',
  'on-hold',
  'open',
  'product backlog',
  'pull request submitted',
  'ready for execution',
  'ready for external share',
  'ready for finalization',
  'ready for qe',
  'ready for test',
  'ready for test/ review complet',
  'ready for test/review complete',
  'ready to begin',
  'ready to review',
  'request created',
  'review',
  'rework',
  'seen',
  'scoping',
  'selected for development',
  'stale/abandoned',
  'test done',
  'test plan in progress',
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
  'engineer testing',
  'in dev test',
  'in progress',
  'in review',
  'in test',
  'in validation',
  'pull request submitted',
  'ready to review',
  'ready for qe',
  'ready for test',
  'ready for test/ review complet',
  'ready for test/review complete',
  'rework',
  'review',
  'test done',
  'to test',
]

CycleTimeNotInFlightIssueStatuses = [
  'abandoned',
  'abandoned in development',
  'assigned',
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
  'hold',
  'investigations',
  'merged',
  'new',
  'on-hold',
  'open',
  'pending production deployment',
  'product backlog',
  'ready for execution',
  'ready for external share',
  'ready for finalization',
  'ready to begin',
  'request created',
  'seen',
  'scoping',
  'selected for development',
  'stale/abandoned',
  'test plan in progress',
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
