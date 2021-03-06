require "timeout"

module Resque
  module Mailer
    MAX_ATTEMPTS = 3

    RETRYABLE_EXCEPTIONS = [
      Timeout::Error,
      Net::OpenTimeout,
      Errno::EPIPE,
      Errno::EHOSTUNREACH,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      SocketError,
      EOFError
    ]

    class << self
      attr_accessor :default_queue_name, :default_queue_target
      attr_reader :excluded_environments

      def excluded_environments=(envs)
        @excluded_environments = [*envs].map { |e| e.to_sym }
      end

      def included(base)
        base.extend(ClassMethods)
      end
    end

    self.default_queue_target = ::Resque
    self.default_queue_name = "mailer"
    self.excluded_environments = [:test]

    module ClassMethods
      def current_env
        ::Rails.env
      end

      def method_missing(method_name, *args)
        return super if environment_excluded?

        if action_methods.include?(method_name.to_s)
          MessageDecoy.new(self, method_name, *args)
        else
          super
        end
      end

      def perform(attempt_number, action, *args)
        self.send(:new, action, *args).message.deliver
      rescue *(RETRYABLE_EXCEPTIONS + @additional_errors_to_retry.to_a)
        raise if attempt_number >= MAX_ATTEMPTS
        resque.enqueue(self, attempt_number + 1, action, *args)
      end

      def additional_errors_to_retry(errors)
        @additional_errors_to_retry = errors
      end

      def environment_excluded?
        !ActionMailer::Base.perform_deliveries || excluded_environment?(current_env)
      end

      def queue
        ::Resque::Mailer.default_queue_name
      end

      def resque
        ::Resque::Mailer.default_queue_target
      end

      def excluded_environment?(name)
        ::Resque::Mailer.excluded_environments && ::Resque::Mailer.excluded_environments.include?(name.to_sym)
      end
    end

    class MessageDecoy
      def initialize(mailer_class, method_name, *args)
        @mailer_class = mailer_class
        @method_name = method_name
        *@args = *args
      end

      def resque
        ::Resque::Mailer.default_queue_target
      end

      def actual_message
        @actual_message ||= @mailer_class.send(:new, @method_name, *@args).message
      end

      def deliver
        resque.enqueue(@mailer_class, attempt=1, @method_name, *@args)
      end

      def deliver!
        actual_message.deliver!
      end

      def method_missing(method_name, *args)
        actual_message.send(method_name, *args)
      end
    end
  end
end
