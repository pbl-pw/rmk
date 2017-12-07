require_relative 'rmk'

class Rmk::Rule < Rmk::Vars
	# create Rule
	# @param upstream [Rmk::Vars, nil] upstream vars for lookup var which current obj not include
	def initialize(upstream, command:)
		super upstream
		@command = command
	end
	attr_reader :command

	def vars; self end

	def each(&cmd) @vars.each &cmd end

	def []=(name, append = false, value) @vars[name] = append ? self[name] + value : value end
end
