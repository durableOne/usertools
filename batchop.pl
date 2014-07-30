#!/usr/bin/perl 
#===============================================================================
#
#         FILE: batchop.pl
#
#        USAGE: batchop.pl file 
#               batchop.pl -h
#               batchop.pl --help
#
#  DESCRIPTION: This script can be used to perform batch operations of user
#               or group management. The input file should contain directives
#               on which of the 6 tools ({user,group}{add,mod,del}) to use
#               and the options to be supplied to the tool in turn.
#               See batchop -h or batchop --help for details on input file
#               syntax
#
#      OPTIONS: -h or --help
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Joseph Riad (joseph.samy.albert@gmail.com), 
#      COMPANY: 
#      VERSION: 1.0
#      CREATED: 07/30/2014 04:11:33 PM
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;

Getopt::Long::Configure( qw(
	no_ignore_case
	bundling
	permute
    )
);

my $input_file;
my $output_file;

# Parse the command line:

GetOptions(
	'o=s'   => \$output_file,
	'h'     => \&usage,
	'help'  => \&usage,
);

$input_file = shift // &usage;
$output_file //= './batchop.err';

for($input_file){
	die "The given input file $_ does not exist!\n"  unless -e;
	die "The given input file $_ is not readable!\n" unless -r
}

open my $FH,'<',$input_file;

my $new_tool = 1;    # Flag to tell us whether we have started a new tool specification
my $need_header = 1; # Flag to tell us whether we have to find the header line yet
my $delimiter = ';'; # Delimiter to be used in parsing the input file

my %invocations;
my $tool_name;
my $header;

while(<$FH>){
	next if /^#/ or /^\s*$/;
	chomp;
	if($new_tool){
		$tool_name = $_;
		if( not -x $tool_name ){
			warn "Tool $_ specified in the input file not found. Skipping...\n";
			$_=<$FH> until /----*/; # Discard input lines until the next new tool.
			next
		}
		$new_tool = 0;
		$need_header = 1;
	} elsif ($need_header){
		$header = $_;
		$need_header = 0;
	} else{
		if (/----*/){
			$new_tool = 1;
			next
		}
		push @{$invocations{$tool_name}{$header}},$_;
	}
}

close $FH;

my $to_print = ''; # To print to the output file in case of failure
for my $tool (keys %invocations){
	for my $header (keys %{$invocations{$tool}}){
		$to_print .= "$tool\n$header\n";
		my @option_names = split /\s*$delimiter\s*/,$header;
		map {
		      if($_ eq '-'){
			      $_ =  ''
			  } elsif (length == 1){
			      $_ = '-'.$_
			  } else {
			      $_ = '--'.$_
			  }
		} @option_names;
		while(my $invocation = shift @{$invocations{$tool}{$header}}){
			my @option_args = split /\s*$delimiter/,$invocation;
			my $command_string ='';
			for(0..$#option_args){
				$command_string .= $option_names[$_] . ' ' . $option_args[$_] . ' ';
			}
			$command_string = $tool . ' ' . $command_string;
			if( system($command_string) ){ # Execution failed
				$to_print .= "$invocation\n";
			}
		}
	}
	$to_print .= "---\n";
}

open my $OFH,'>',$output_file;
print $OFH $to_print;

sub usage{
	warn <<EOI;
Usage
	  batchop.pl [-o outfile] file
	  batchop.pl -h
	  batchop.pl --help

Options
	  -h --help               Print this help message and exit,
	  -o                      Specify the output file to dump
	                          failed entries in. This defaults to
	                          ./batchop.err

Description
      batchop.pl can be used to perform batch operations of user
      or group management. The input file should contain directives
      on which of the 6 tools ({user,group}{add,mod,del}) to use
      and the options to be supplied to the tool in turn.

Input file syntax
	  The name of the tool to be invoked should be given on a separate 
	  line followed by a semicolon-delimited line specifying the names 
	  of the options to be supplied to the tool.
	  The argument to be passed to the tool (i.e. the login name or group
	  name) should be named - on the first line.
	  After that, each invocation of the tool is denoted by a semicolon-
	  delimited entry listing the arguments to be given to each option
	  in the order the option names were specified on the header line.
	  Boolean options should have an empty arugment.
	  You can invoke more than one tool. Separate the entries for each tool
	  by a line of 3 or more dashes '---(-)*'.
	  Example:
	  useradd
	  -;password;c;m;b
	  user;pass;User;;/home
	  ----
	  userdel
	  -
	  luser
	  This will result in the following invocations:
	  useradd --password pass -c User -b /home -m user
	  userdel luser
	  Any invocations that fail will have their entries written to the
	  output file specified by -o or ./batchop.err by default.
	  This way, you can fix whatever error prevented the previous batch
	  operation and rerun batchop.pl using the output file generated.
	  Lines starting with a `#` and blank lines are ignored.
EOI
	exit 0
}
