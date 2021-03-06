require File.join(File.expand_path(File.dirname(__FILE__)), 'spec_helper')

class FakeResque
  def self.enqueue(*args); end
end

CustomError = Class.new(StandardError)

class Rails3Mailer < ActionMailer::Base
  include Resque::Mailer
  default :from => "from@example.org", :subject => "Subject"
  MAIL_PARAMS = { :to => "crafty@example.org" }

  def test_mail(*params)
    Resque::Mailer.success!
    mail(*params)
  end
end

class Rails3MailerWithCustomError < Rails3Mailer
  additional_errors_to_retry [ CustomError ]
end

describe Resque::Mailer do
  let(:resque) { FakeResque }

  before do
    Resque::Mailer.default_queue_target = resque
    Resque::Mailer.stub(:success!)
    Rails3Mailer.stub(:current_env => :test)
  end

  describe "resque" do
    it "allows overriding of the default queue target (for testing)" do
      Resque::Mailer.default_queue_target = FakeResque
      Rails3Mailer.resque.should == FakeResque
    end
  end

  describe "queue" do
    it "defaults to the 'mailer' queue" do
      Rails3Mailer.queue.should == "mailer"
    end

    it "allows overriding of the default queue name" do
      Resque::Mailer.default_queue_name = "postal"
      Rails3Mailer.queue.should == "postal"
    end
  end

  describe '#deliver' do
    before(:all) do
      @delivery = lambda {
        Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).deliver
      }
    end

    it 'should not deliver the email synchronously' do
      lambda { @delivery.call }.should_not change(ActionMailer::Base.deliveries, :size)
    end

    it 'should place the deliver action on the Resque "mailer" queue' do
      resque.should_receive(:enqueue).with(Rails3Mailer, 1, :test_mail, Rails3Mailer::MAIL_PARAMS)
      @delivery.call
    end

    context "when current env is excluded" do
      it 'should not deliver through Resque for excluded environments' do
        Resque::Mailer.stub(:excluded_environments => [:custom])
        Rails3Mailer.should_receive(:current_env).and_return(:custom)
        resque.should_not_receive(:enqueue)
        @delivery.call
      end
    end

    it 'should not invoke the method body more than once' do
      Resque::Mailer.should_not_receive(:success!)
      Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).deliver
    end
  end

  describe '#deliver!' do
    it 'should deliver the email synchronously' do
      lambda { Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).deliver! }.should change(ActionMailer::Base.deliveries, :size).by(1)
    end
  end

  describe 'perform' do
    it 'should perform a queued mailer job' do
      lambda {
        Rails3Mailer.perform(1, :test_mail, Rails3Mailer::MAIL_PARAMS)
      }.should change(ActionMailer::Base.deliveries, :size).by(1)
    end
  end

  describe 'error handling' do
    Resque::Mailer::RETRYABLE_EXCEPTIONS.each do |exception_class|
      it "reschedules on #{exception_class} errors" do
        Mail::Message.any_instance.stub(:deliver).and_raise(exception_class)

        resque.should_receive(:enqueue).with(Rails3Mailer, 2, :test_mail, Rails3Mailer::MAIL_PARAMS)

        lambda {
          Rails3Mailer.perform(1, :test_mail, Rails3Mailer::MAIL_PARAMS)
        }.should_not change(ActionMailer::Base.deliveries, :size)
      end
    end

    it "supports custom exceptions for specific mailers" do
      Mail::Message.any_instance.stub(:deliver).and_raise(CustomError)

      resque.should_receive(:enqueue).with(Rails3MailerWithCustomError, 2, :test_mail, Rails3Mailer::MAIL_PARAMS)

      lambda {
        Rails3MailerWithCustomError.perform(1, :test_mail, Rails3Mailer::MAIL_PARAMS)
      }.should_not change(ActionMailer::Base.deliveries, :size)
    end

    it "does not leak custom errors between mailers" do
      Mail::Message.any_instance.stub(:deliver).and_raise(CustomError)

      resque.should_not_receive(:enqueue)

      lambda {
        Rails3Mailer.perform(1, :test_mail, Rails3Mailer::MAIL_PARAMS)
      }.should raise_exception(CustomError)
    end

    it "doesn't reschedule on unknown errors" do
      Mail::Message.any_instance.stub(:deliver).and_raise("Some unknown error")

      resque.should_not_receive(:enqueue)

      lambda {
        Rails3Mailer.perform(1, :test_mail, Rails3Mailer::MAIL_PARAMS)
      }.should raise_exception("Some unknown error")
    end

    it 'raises after 3 failed attempts' do
      Mail::Message.any_instance.stub(:deliver).and_raise(Timeout::Error)

      resque.should_not_receive(:enqueue)
      lambda {
        Rails3Mailer.perform(3, :test_mail, Rails3Mailer::MAIL_PARAMS)
      }.should raise_exception(Timeout::Error)
    end
  end

  describe 'original mail methods' do
    it 'should be preserved' do
      Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).subject.should == 'Subject'
      Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).from.should include('from@example.org')
      Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).to.should include('crafty@example.org')
    end

    it 'should require execution of the method body prior to queueing' do
      Resque::Mailer.should_receive(:success!).once
      Rails3Mailer.test_mail(Rails3Mailer::MAIL_PARAMS).subject
    end
  end
end
