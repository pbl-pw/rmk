class Rmk; end

module Rmk::Schedule
	Thread.abort_on_exception = true
	@queue = SizedQueue.new 8

	def self.new_thread!(&cmd)
		Thread.new do
			@queue.push nil
			result = cmd.call
			@queue.pop
			result
		end
	end
end
