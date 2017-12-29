require_relative 'rmk'

class Rmk::Rule < Rmk::Vars
	# create Rule
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream, command:)
		super upstream.rmk, upstream
		@command = command
	end
	attr_reader :command

	def vars; self end

	def []=(name, append = false, value) store name, append ? self[name].to_s + value : value end
end
