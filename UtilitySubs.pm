#
#===============================================================================
#
#         FILE: UtilitySubs.pm
#
#  DESCRIPTION: Collection of utility subroutines shared by all user tools 
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Joseph Riad (joseph.samy.albert@gmail.com), 
#      COMPANY: 
#      VERSION: 1.0
#      CREATED: 07/28/2014 03:16:08 PM
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use Authen::SASL qw(XS);
use Authen::Krb5;
use Authen::Krb5::Easy qw(kinit kdestroy kerror);
use Authen::Krb5::Admin qw(:constants);
use Sys::Hostname::Long;
use File::Temp qw(tempfile);
use Net::LDAP;

my $krb_file = '/etc/krb5.conf';
my $nslcd_file = '/etc/nslcd.conf';

# Initialize common Kerberos and LDAP options:
for my $option (qw( unsupported keytab principal realm server base )){
	$main::options{$option} = undef;
}

#-------------------------------------------------------------------------------
#
# handler ($)
# Checks whether an option is currently supported by searching for the package
# variable called handle_<option>. Returns a reference to the handler if
# it exists
#
#-------------------------------------------------------------------------------

sub handler ($) { return $main::{"handle_$_[0]"} }

#-------------------------------------------------------------------------------
#
# handle_option
# Calls an option handler if it's supported otherwise prints a warning
# message
#
#-------------------------------------------------------------------------------

sub handle_option {
	my ($option,$value) = @_;
	if ( my $handler=handler $option) { $main::options{$option} = &$handler($option,$value)      }
	else                              { warn "Option $option is currently not supported\n" }
}

#-------------------------------------------------------------------------------
#
# supported
# Returns whether or not a handler function exists for the given option name
#
#-------------------------------------------------------------------------------

sub supported{ return defined handler $_[0] }

#-------------------------------------------------------------------------------
#
# obtain_option_defaults
# Loops over the %options hash to find options with undefined values
# and attempts its best to fill these options with their default values
# as defined in the useradd(8) man page.
#
#-------------------------------------------------------------------------------

sub obtain_option_defaults{
	no strict 'refs';
	for my $option  # Look for supported short options with unspecified values:
	  (grep { supported $_ and ! defined $main::options{$_} } sort keys %main::options){
		  # Call the subroutine that obtains the option's default value if it exists:
		  $main::options{$option} = &{"main::default_$option"} if exists ${main::}{"default_$option"} ;
		  if( exists $main::synonyms{$option} ) { $main::options{$main::synonyms{$option}} = $main::options{$option} }
    }
}

#-------------------------------------------------------------------------------
#
# open_file
# Opens a read handle to the specified file and returns the handle
# (to lump boilerplate file opening code)
#
#-------------------------------------------------------------------------------

sub open_file ($){
	my $file = shift;
    die "open_file: no file specified!\n" unless defined $file;
	die "The file $file is a link. Possible malicious intent. Aborting!\n" if -l $file;
	# Stat the file and the opened handle:
	my @stat = stat $file;
	open my $handle,'<',$file or die "Failed to open $file: $!\n";
	my @hstat = stat $handle;
	# Abort if you find a race condition:
	die "The file $file has been changed since a handle was opened to it. Aborting!\n" 
	  if grep { $stat[$_] ne $hstat[$_] } (0..$#stat);
	$handle
}

#-------------------------------------------------------------------------------
#
# parse_config
# Takes the name of a configuration file and parses its lines into the
# hash of hashes %config_files. This subroutine assumes the variable names and
# values are separated either by an '=' (as in /etc/default/useradd) or by 
# whitespace (as in /etc/login.defs)
#
#-------------------------------------------------------------------------------

sub parse_config ($;$){
	my $file = shift;
	my $separator_regex = shift // qr{ (?:\s*=\s* | \s+) }x; 
	# Default separator is either an equals sign or some white space
	my $config_fh = open_file $file;
	return if defined $main::config_files{$file}; # This file has already been parsed
	local $/="\n";
	while(<$config_fh>){
		next if /^#/ or /^\s*$/; # Skip comments and empty lines
		my ($var,$value) = /^\s*([_a-z]\w*) # Variable name (captured)
							 $separator_regex
							 (\S+)          # Variable value (captured)
		                   /ix;
		next unless defined $value; # No value on this line
		$var   =~ s/^\s*//;
		$value =~ s/\s*$//;
		$main::config_files{$file}{$var} = $value;
	} # End while
	close $config_fh or die "Failed to close handle on file $file: $!\n";
}

#-------------------------------------------------------------------------------
#
# install_synonyms
# Installs aliases for synonymous commands so that they're handled by the same
# handler. It only installs aliases for supported commands
#
#-------------------------------------------------------------------------------

sub install_synonyms{
   no strict 'refs';
   for my $key (keys %main::synonyms){
	   if(exists ${main::}{"handle_$key"}){ 
		   my $synonym = $main::synonyms{$key}; 
		   *{"main::handle_$synonym"} = *{"main::handle_$key"};
	   }
   }
}

#-------------------------------------------------------------------------------
#
# obtain_krb_creds
# Attempt to obtain a Kerberos ticket for the specified principal and realm
# using the specified keytab
#
#-------------------------------------------------------------------------------

sub obtain_krb_creds {
	die "No principal to authenticate as!\n" unless defined $main::options{principal};
	die "No keytab file given!\n" unless defined $main::options{keytab};
	die "Can't read the keytab file $main::options{keytab}!\n" unless -r $main::options{keytab};
	die "No realm given!\n" unless defined $main::options{realm};
	my (undef,$cred_cache_file) = 
	                      tempfile( DIR  => '/tmp', # Make a temp. file to hold 
						            OPEN => 0 );    # the credentials cache
	$ENV{KRB5CCNAME} = $cred_cache_file;
	kinit($main::options{keytab},$main::options{principal}.'@'.$main::options{realm}) or die "Kerberos error on kinit: ".kerror;
	return $cred_cache_file
}

#-------------------------------------------------------------------------------
#
# bind_to_ldap_server
#
#-------------------------------------------------------------------------------

sub bind_to_ldap_server {
	my $base_as_cn = join '.', split /,dc=/,$main::options{base}; #Convert the base 
	$base_as_cn =~ s/^dc=/cn=/; # from dc=example,dc=com  to cn=example.com
	my $sasl_object = Authen::SASL->new( mechanism => 'GSSAPI' ) or die "$@\n";
	my $ldap_object = Net::LDAP->new($main::options{server});
	die "LDAP server seems down!\n" unless defined $ldap_object;
	my $ldap_bind = $ldap_object->bind( 
		sasl => $sasl_object,
	);
	$ldap_object
}

#-------------------------------------------------------------------------------
#
# destroy_krb_creds
# Destroy any Kerberos credentials the script previously obtained
#
#-------------------------------------------------------------------------------

sub destroy_krb_creds { kdestroy or die "Kerberos error on kdestroy ".kerror }

#-------------------------------------------------------------------------------
#
# getgid
# Returns a gid given the group name or gid
#
#-------------------------------------------------------------------------------

sub getgid{
	my $group = shift;
	return $group if $group=~ /^[0-9]+$/;
	my @group_data = getgrnam($group);
	return $group_data[2]
}

#-------------------------------------------------------------------------------
#
# getgname
# Returns a group's name given the group name or gid 
#
#-------------------------------------------------------------------------------

sub getgname{
	my $group = shift;
	return $group unless $group=~ /^[0-9]+$/;
	my @group_data = getgrgid($group);
	return $group_data[0]
}

#-------------------------------------------------------------------------------
#
# ldap_is_up
# Attempts to bind to the LDAP server and immediately unbinds if the bind
# is successful. Depending on whether or not bind_to_ldap_server threw an
# exception, it decides whether the server is up
#
#-------------------------------------------------------------------------------


sub ldap_is_up {
	eval { &bind_to_ldap_server->unbind() };
	return $@ ? undef : 1
}
#-------------------------------------------------------------------------------
#
# get_newid
# Returns a new, unused user or group ID
#
#-------------------------------------------------------------------------------


sub get_newid ($) {
	my $entity = shift//'user';
	my $logindefs_file = shift;
	my ($min,$max,$id,@IDs);
	# First, make sure the LDAP server is up:
	die "LDAP server seems down. New $entity ID will be unreliable!\n" unless &ldap_is_up;
	parse_config $logindefs_file;
	my @ID;
	if( $entity eq 'user'){
		$min = $main::config_files{$logindefs_file}{UID_MIN}//1000;
		$max = $main::config_files{$logindefs_file}{UID_MAX}//60_000;
		push @IDs, $ID[2] while @ID = getpwent;
	}
	elsif ( $entity eq 'group'){
		$min = $main::config_files{$logindefs_file}{GID_MIN}//1000;
		$max = $main::config_files{$logindefs_file}{GID_MAX}//60_000;
		push @IDs, $ID[2] while @ID = getgrent;
	}
	else{
		die "get_newid: I don't know what to do with the argument $entity!\n";
	}
	@IDs = sort { $b <=> $a } @IDs;
	while($id = shift @IDs){
		if ( $id <= $max && $id >= $min ){
			last
		}
	}
	++$id
}

#-------------------------------------------------------------------------------
#
# group_exists
# Returns whether the specified group exists
#
#-------------------------------------------------------------------------------

sub group_exists{
	my $group = shift;
	while($_ = getgrent){
		return 1 if( $group eq $_ )
	}
	undef # If we reach this point, the group doesn't exist
}

#-------------------------------------------------------------------------------
#
# add_common_help_message
# Adds the common options relating to LDAP and Kerberos and not supported
# by the original tool
#
#-------------------------------------------------------------------------------

sub add_common_help_message{
	  return <<EOI;
  --unsupported                 list the switches of $0(8) that this script 
                                does not support
Additonal options: (for Kerberos and LDAP)
  --keytab                      keytab containing administrative user credentials for binding
                                to the LDAP server. Defaults to /etc/krb5.keytab,
  --principal                   Kerberos administrative prinicpal. Defaults to
                                root/admin@<Default Realm>,
  --realm                       Kerberos realm to use for authentication. Defaults to the
                                default realm. Ignored if --principal is of the form
                                <principal>@<Realm>,
  --server                      The URI of the LDAP server that stores your user information.
                                If not supplied, the file /etc/nslcd.conf is parsed in an
                                attempt to find it. If no info is found, it defaults to
                                ldap://<name of local host>,
  --base                        Base to be used in constructing LDAP DNs. If not supplied,
                                the file /etc/nslcd.conf is parsed in order to find it. If
                                no info is found, it defaults to dc=<Kerberos Realm>
EOI
}

#-------------------------------------------------------------------------------
#
# Handlers for LDAP and Kerberos Options 
#
#-------------------------------------------------------------------------------

sub handle_keytab    { $_[1] }
sub handle_principal { 
	my ($o,$v) = @_;
	if ($v =~ /@(.*)$/){ # Realm specified along with principal
		$main::options{realm} = $1;
	}
	$v
}
sub handle_realm     {
	my ($o,$v) = @_;
	if ( defined $main::options{realm} ) { # Realm has been set by --principal
		$v = $main::options{realm}
	}
	$v
}

sub handle_server    { $_[1] }
sub handle_base      { $_[1] }

#-------------------------------------------------------------------------------
#
# Default handlers for LDAP and Kerberos Options 
#
#-------------------------------------------------------------------------------


sub default_keytab {
	$main::options{keytab} = '/etc/krb5.keytab'
}

sub default_principal{
	$main::options{principal} = 'root/admin'
}

sub default_realm{
	parse_config $krb_file;
	$main::options{realm} = $main::config_files{$krb_file}{default_realm};
}

sub default_server{
	parse_config $nslcd_file;
	$main::options{server} = $main::config_files{$nslcd_file}{uri} // 'ldap://'.hostname_long
}

sub default_base{
	parse_config $nslcd_file;
	my $fallback;
	defined $main::options{realm} or &default_realm; # First make sure that we have a realm
	$fallback = 'dc='. join ',dc=',split /\./, lc $main::options{realm};
	$main::options{base} = $main::config_files{$nslcd_file}{base} // $fallback
}

#-------------------------------------------------------------------------------
#
# build_kadm_object
# Returns an object of class Authen::Krb5::Admin
# that can be used to manipulate Kerberos principals
#
#-------------------------------------------------------------------------------

sub build_kadm_object{
	my $krb5_config = new Authen::Krb5::Admin::Config;
	$krb5_config->realm($main::options{realm});
	Authen::Krb5::init_context or die Authen::Krb5::error;
	my $krb5_admin = Authen::Krb5::Admin->init_with_skey(
													$main::options{principal},
													$main::options{keytab},
													KADM5_ADMIN_SERVICE,
													$krb5_config
												);
}

1
