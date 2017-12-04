require_relative 'rmk/rmk'
require 'optparse'

options = {outroot:'_Build', srcroot:'..'}
targets = OptionParser.new{ |opts|
	opts.summary_width = 48
	opts.banner = 'Usage��rmk [Options] [targets]'
	opts.separator ''
	opts.on '-C', '--directory=dir', 'output root dir,can be absolute or relative to pwd,default _Build' do |dir|
		options[outroot:dir]
	end
	opts.on '-S', '--source=dir', 'source root dir,can be absolute or relative to output root(start with ..),default ..' do |dir|
		options[srcroot:dir]
	end
	opts.on '-h', '--help', 'show this help' do
		puts opts
		exit
	end
	opts.on '-v', '--version', 'show version' do
		puts 'rmk 0.1.0', ''
		exit
	end
}.parse(argv)
::Rmk.new(srcroot:options[:srcroot], outroot:options[:outroot]).build targets
