module Sidekiq::LimitFetch::Queues
  extend self

  THREAD_KEY = :acquired_queues

  def start(capsule_or_options)
    config = Sidekiq::LimitFetch.post_7? ? capsule_or_options.config : capsule_or_options

    @queues         = config[:queues]
    @startup_queues = config[:queues].dup

    if config[:dynamic].is_a? Hash
      @dynamic         = true
      @dynamic_exclude = config[:dynamic][:exclude] || []
    else
      @dynamic = config[:dynamic]
      @dynamic_exclude = []
    end

    @limits         = config[:limits] || {}
    @process_limits = config[:process_limits] || {}
    @blocks         = config[:blocking] || []

    config[:strict] ? strict_order! : weighted_order!

    apply_process_limit_to_queues
    apply_limit_to_queues
    apply_blocks_to_queues
  end

  def acquire
    queues = saved
    queues ||= Sidekiq::LimitFetch.redis_retryable do
      selector.acquire(ordered_queues, namespace)
    end
    save queues
    queues.map { |it| "queue:#{it}" }
  end

  def release_except(full_name)
    queues = restore
    queues.delete full_name[/queue:(.*)/, 1] if full_name
    Sidekiq::LimitFetch.redis_retryable do
      selector.release queues, namespace
    end
  end

  def dynamic?
    @dynamic
  end

  def startup_queue?(queue)
    @startup_queues.include?(queue)
  end

  def dynamic_exclude
    @dynamic_exclude
  end

  def add(queues)
    return unless queues
    queues.each do |queue|
      unless @queues.include? queue
        if startup_queue?(queue)
          apply_process_limit_to_queue(queue)
          apply_limit_to_queue(queue)
        end

        @queues.push queue
      end
    end
  end

  def remove(queues)
    return unless queues
    queues.each do |queue|
      if @queues.include? queue
        clear_limits_for_queue(queue)
        @queues.delete queue
        Sidekiq::Queue.delete_instance(queue)
      end
    end
  end

  def handle(queues)
    add(queues - @queues)
    remove(@queues - queues)
  end

  def strict_order!
    @queues.uniq!
    def ordered_queues; @queues end
  end

  def weighted_order!
    def ordered_queues; @queues.shuffle.uniq end
  end

  def namespace
    @namespace ||= Sidekiq.redis do |it|
      if it.respond_to?(:namespace) and it.namespace
        "#{it.namespace}:"
      else
        ''
      end
    end
  end

  private

  def apply_process_limit_to_queues
    @queues.uniq.each do |queue_name|
      apply_process_limit_to_queue(queue_name)
    end
  end

  def apply_process_limit_to_queue(queue_name)
    queue = Sidekiq::Queue[queue_name]
    queue.process_limit = @process_limits[queue_name.to_s] || @process_limits[queue_name.to_sym]
  end

  def apply_limit_to_queues
    @queues.uniq.each do |queue_name|
      apply_limit_to_queue(queue_name)
    end
  end

  def apply_limit_to_queue(queue_name)
    queue = Sidekiq::Queue[queue_name]

    unless queue.limit_changed?
      queue.limit = @limits[queue_name.to_s] || @limits[queue_name.to_sym]
    end
  end

  def apply_blocks_to_queues
    @queues.uniq.each do |queue_name|
      Sidekiq::Queue[queue_name].unblock
    end

    @blocks.to_a.each do |it|
      if it.is_a? Array
        it.each {|name| Sidekiq::Queue[name].block_except it }
      else
        Sidekiq::Queue[it].block
      end
    end
  end

  def clear_limits_for_queue(queue_name)
    queue = Sidekiq::Queue[queue_name]
    queue.clear_limits
  end

  def selector
    Sidekiq::LimitFetch::Global::Selector
  end

  def saved
    Thread.current[THREAD_KEY]
  end

  def save(queues)
    Thread.current[THREAD_KEY] = queues
  end

  def restore
    saved || []
  ensure
    save nil
  end
end
