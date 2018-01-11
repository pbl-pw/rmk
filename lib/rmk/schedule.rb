class Rmk; end

module Rmk::Schedule
	Thread.abort_on_exception = true

	def self.new_thread!(&cmd)
		Thread.new &cmd
	end
end
