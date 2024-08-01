# frozen_string_literal: true

class Scheduler::AccountsStatusesCleanupScheduler
  include Sidekiq::Worker
  include Redisable
  include LowPriorityScheduler

  # This limit is mostly to be nice to the fediverse at large and not
  # generate too much traffic.
  # This also helps limiting the running time of the scheduler itself.
  MAX_BUDGET         = 300

  # This is an attempt to spread the load across remote servers, as
  # spreading deletions across diverse accounts is likely to spread
  # the deletion across diverse followers. It also helps each individual
  # user see some effect sooner.
  PER_ACCOUNT_BUDGET = 5

  # This is an attempt to limit the workload generated by status removal
  # jobs to something the particular server can handle.
  PER_THREAD_BUDGET  = 5

  sidekiq_options retry: 0, lock: :until_executed, lock_ttl: 1.day.to_i

  def perform
    return if under_load?

    budget = compute_budget

    # If the budget allows it, we want to consider all accounts with enabled
    # auto cleanup at least once.
    #
    # We start from `first_policy_id` (the last processed id in the previous
    # run) and process each policy until we loop to `first_policy_id`,
    # recording into `affected_policies` any policy that caused posts to be
    # deleted.
    #
    # After that, we set `full_iteration` to `false` and continue looping on
    # policies from `affected_policies`.
    first_policy_id   = last_processed_id || 0
    first_iteration   = true
    full_iteration    = true
    affected_policies = []

    loop do
      num_processed_accounts = 0

      scope = cleanup_policies(first_policy_id, affected_policies, first_iteration, full_iteration)
      scope.find_each(order: :asc) do |policy|
        num_deleted = AccountStatusesCleanupService.new.call(policy, [budget, PER_ACCOUNT_BUDGET].min)
        budget -= num_deleted

        unless num_deleted.zero?
          num_processed_accounts += 1
          affected_policies << policy.id if full_iteration
        end

        full_iteration = false if !first_iteration && policy.id >= first_policy_id

        if budget.zero?
          save_last_processed_id(policy.id)
          break
        end
      end

      # The idea here is to loop through all policies at least once until the budget is exhausted
      # and start back after the last processed account otherwise
      break if budget.zero? || (num_processed_accounts.zero? && !full_iteration)

      full_iteration  = false unless first_iteration
      first_iteration = false
    end
  end

  def compute_budget
    # Each post deletion is a `RemovalWorker` job (on `default` queue), each
    # potentially spawning many `ActivityPub::DeliveryWorker` jobs (on the `push` queue).
    threads = Sidekiq::ProcessSet.new.select { |x| x['queues'].include?('push') }.pluck('concurrency').sum
    [PER_THREAD_BUDGET * threads, MAX_BUDGET].min
  end

  private

  def cleanup_policies(first_policy_id, affected_policies, first_iteration, full_iteration)
    scope = AccountStatusesCleanupPolicy.where(enabled: true)

    if full_iteration
      # If we are doing a full iteration, examine all policies we have not examined yet
      if first_iteration
        scope.where(id: first_policy_id...)
      else
        scope.where(id: ..first_policy_id).or(scope.where(id: affected_policies))
      end
    else
      # Otherwise, examine only policies that previously yielded posts to delete
      scope.where(id: affected_policies)
    end
  end

  def last_processed_id
    redis.get('account_statuses_cleanup_scheduler:last_policy_id')&.to_i
  end

  def save_last_processed_id(id)
    if id.nil?
      redis.del('account_statuses_cleanup_scheduler:last_policy_id')
    else
      redis.set('account_statuses_cleanup_scheduler:last_policy_id', id, ex: 1.hour.seconds)
    end
  end
end
