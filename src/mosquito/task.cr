module Mosquito
  # A Task is a unit of work which will be performed by a Job.
  # Tasks know how to:
  # - store and retrieve their data to and from the datastore
  # - figure out what Job class they match to
  # - build an instance of that Job class and pass off the config data
  # - Ask the job to run
  #
  # Task data is called `config` and is persisted as a Hash in Redis under the key
  # `mosquito:task:task_id`.
  class Task
    getter type
    getter enqueue_time : Time?
    getter id : String?
    getter retry_count = 0
    getter job : Mosquito::Job

    property config

    ID_PREFIX = {"mosquito", "task"}

    def redis_key(*parts)
      Redis.key ID_PREFIX, parts
    end

    def self.new(type : String)
      new(type, nil, nil, 0)
    end

    private def initialize(
      @type : String,
      @enqueue_time : Time | Nil,
      @id : String | Nil,
      @retry_count : Int32,
    )
      @config = {} of String => String
      @job = NilJob.new
    end

    def store
      @enqueue_time = time = Time.now
      epoch = time.epoch_ms.to_s

      unless task_id = @id
        task_id = @id = redis_key epoch, rand(1000).to_s
      end

      fields = config.dup
      fields["enqueue_time"] = epoch
      fields["type"] = type
      fields["retry_count"] = retry_count.to_s

      Redis.instance.store_hash task_id, fields
    end

    def delete
      keys = Redis.instance.hkeys id
      keys.each do |key|
        Redis.instance.hdel id, key
      end
    end

    def run
      @job = instance = Base.job_for_type(type).new

      if instance.is_a? QueuedJob
        instance.vars_from(config)
      end

      instance.task_id = id
      instance.run

      if failed?
        @retry_count += 1
        store
      end
    end

    def fail
      @retry_count += 1
      # TODO does this incremenet the retry_count?
      puts Redis.instance.hgetall id
      store
    end

    def rescheduleable?
      @job.rescheduleable? && @retry_count < 5
    end

    def reschedule_interval
      2.seconds * (@retry_count ** 2)
      # retry 1 = 2 minutes
      #       2 = 8
      #       3 = 18
      #       4 = 32
    end

    delegate :executed?, :succeeded?, :failed?, :failed, :rescheduled, to: @job

    def self.retrieve(id : String)
      fields = Redis.instance.retrieve_hash id

      return unless name = fields.delete "type"
      return unless timestamp = fields.delete "enqueue_time"
      retry_count = (fields.delete("retry_count") || 0).to_i

      instance = new(name, Time.epoch_ms(timestamp.to_i64), id, retry_count)
      instance.config = fields

      instance
    end

    def to_s(io : IO)
      "#{type}<#{id}>".to_s(io)
    end
  end
end
