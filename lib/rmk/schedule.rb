class Rmk; end

class Rmk::Schedule
	Thread.abort_on_exception = true
	@thread_run_mutex = Thread::Mutex.new
	@waitting_threads = []
	@running_threads_cnt = 1

	class << self
		private def default_thread_body(cmd)
			Thread.stop unless @thread_run_mutex.synchronize do
				next @running_threads_cnt += 1 unless @running_threads_cnt >= 8
				@waitting_threads << Thread.current
				false
			end
			result = cmd.call
			@thread_run_mutex.synchronize do
				if @waitting_threads.empty?
					@running_threads_cnt -= 1 unless @running_threads_cnt <= 0
				else
					@waitting_threads.shift.run
				end
			end
			result
		end

		def new_thread!(&cmd) Thread.new cmd, &method(:default_thread_body) end
	end
end
