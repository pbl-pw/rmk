class Rmk; end

module Rmk::Schedule
	Thread.abort_on_exception = true
	@queue = SizedQueue.new 8
	@message = Queue.new
	@thread = Thread.new do
		while true
			@message.push nil if @queue.empty?
			Thread.stop
		end
	end

	def self.new_thread!(&cmd)
		Thread.new do
			@queue.push nil
			result = cmd.call
			@queue.pop
			@thread.wakeup
			result
		end
	end

	def self.wait_all;@message.clear; @thread.wakeup; @message.pop end
end
