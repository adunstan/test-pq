
# Copyright (c) 2021-2024, PostgreSQL Global Development Group

=pod

=head1 NAME

PostgreSQL::Test::RemoteCluster - class representing PostgreSQL server instance

=head1 SYNOPSIS

  use PostgreSQL::Test::RemoteCluster;

  my $node = PostgreSQL::Test::Cluster->new(name, host, port);

  # run a query with psql, like:
  #   echo 'SELECT 1' | psql -qAXt postgres -v ON_ERROR_STOP=1
  $psql_stdout = $node->safe_psql('postgres', 'SELECT 1');

  # Run psql with a timeout, capturing stdout and stderr
  # as well as the psql exit code. Pass some extra psql
  # options. If there's an error from psql raise an exception.
  my ($stdout, $stderr, $timed_out);
  my $cmdret = $node->psql('postgres', 'SELECT pg_sleep(600)',
	  stdout => \$stdout, stderr => \$stderr,
	  timeout => $PostgreSQL::Test::Utils::timeout_default,
	  timed_out => \$timed_out,
	  extra_params => ['--single-transaction'],
	  on_error_die => 1)
  print "Sleep timed out" if $timed_out;

  # Similar thing, more convenient in common cases
  my ($cmdret, $stdout, $stderr) =
      $node->psql('postgres', 'SELECT 1');

  # run query every second until it returns 't'
  # or times out
  $node->poll_query_until('postgres', q|SELECT random() < 0.1;|')
    or die "timed out";

  # try connections until we can connect
  $node->poll_until_connection($dbname);

=head1 DESCRIPTION

PostgreSQL::Test::RemoteCluster contains a set of routines able to work on a
remote PostgreSQL node.

In addition it has some wrappers around Test::More functions to run commands
with an environment set up to point to the instance.

The IPC::Run module is required.

=cut

package PostgreSQL::Test::RemoteCluster;

use strict;
use warnings FATAL => 'all';

BEGIN
{
	# for now require use of the XS library
	# do this before usinf PostgreSQL::Test::Session so it
	# uses the right setup in its BEGIN block
	$ENV{PG_USE_PQ_XS} = 1;
}

use Carp;
use Config;
use IPC::Run;
use Test::More;
use PostgreSQL::Test::Utils          ();
use PostgreSQL::Test::Session;
use Time::HiRes                      qw(usleep);
use File::Basename;

our ($use_tcp, $test_localhost, $test_pghost, $last_host_assigned,
	$last_port_assigned, @all_nodes, $died, $portdir);

=pod

=head1 METHODS

=over

=item $node->port()

Get the port number assigned to the host. This won't necessarily be a TCP port
open on the local host since we prefer to use unix sockets if possible.

Use $node->connstr() if you want a connection string.

=cut

sub port
{
	my ($self) = @_;
	return $self->{_port};
}

=pod

=item $node->host()

Return the host (like PGHOST) for this instance. May be a UNIX socket path.

Use $node->connstr() if you want a connection string.

=cut

sub host
{
	my ($self) = @_;
	return $self->{_host};
}

=pod

=item $node->name()

The name assigned to the node at creation time.

=cut

sub name
{
	my ($self) = @_;
	return $self->{_name};
}

=pod

=item $node->connstr()

Get a libpq connection string that will establish a connection to
this node. Suitable for passing to psql, DBD::Pg, etc.

=cut

sub connstr
{
	my ($self, $dbname) = @_;
	my $pgport = $self->{_port};
	my $pghost = $self->{_host};
	my $paramstr = "";
	while (my ($k,$v) = each %{$self->{_params}})
	{
		# XXX probably need to do some escape quoting here
		$paramstr .= " $k=$v";
	}
	if (!defined($dbname))
	{
		return "port=$pgport host=$pghost$paramstr";
	}

	# Escape properly the database string before using it, only
	# single quotes and backslashes need to be treated this way.
	$dbname =~ s#\\#\\\\#g;
	$dbname =~ s#\'#\\\'#g;

	return "port=$pgport host=$pghost dbname='$dbname'$paramstr";
}

=pod

=item $node->info()

Return a string containing human-readable diagnostic information (paths, etc)
about this node.

=cut

sub info
{
	my ($self) = @_;
	my $_info = '';
	open my $fh, '>', \$_info or die;
	print $fh "Name: " . $self->name . "\n";
	print $fh "Connection string: " . $self->connstr . "\n";
	close $fh or die;
	return $_info;
}

=pod

=item $node->dump_info()

Print $node->info()

=cut

sub dump_info
{
	my ($self) = @_;
	print $self->info;
	return;
}


=pod

=item PostgreSQL::Test::RemoteCluster->new(node_name, host, port, %params)

Build a new object of class C<PostgreSQL::Test::RemoteCluster>
(or of a subclass, if you have one.
=over

=item port => [1,65535]

The port the remote node is using

=item host => 'address'

The host name or IP address of the remote node

=item %params

key value pairs of extra connections string paameters, such as sslmode,
user, passfile.

=cut

sub new
{
	my $class = shift;
	my ($name, $host, $port, %params) = @_;

	my $testname = basename($0);
	$testname =~ s/\.[^.]+$//;
	my $node = {
		_port => $port,
		_host => $host,
		_name => $name,
		_params => { %params },
	};

	bless $node, $class;

	$node->dump_info;

	return $node;
}

=pod

=item $node->safe_psql($dbname, $sql) => stdout

Invoke B<psql> to run B<sql> on B<dbname> and return its stdout on success.
Die if the SQL produces an error. Runs with B<ON_ERROR_STOP> set.

Takes optional extra params like timeout and timed_out parameters with the same
options as psql.

=cut

sub safe_psql
{
	my ($self, $dbname, $sql, %params) = @_;

	my ($stdout, $stderr);

	# for now only use a Session object for single statement sql without
	# any special params
	if  ($sql =~ /\w/ && $sql !~ /;.*\w/s && !scalar(keys(%params)))
	{

		my $session = PostgreSQL::Test::Session->new(
			connstr => $self->connstr($dbname));
		print STDERR "safe_psql has connstr: " , $self->connstr($dbname), "\n";
		die "something went wrong" unless $session;

		my $res = $session->query($sql);
		my $status = $res->{status};
		$stdout = $res->{psqlout} // "";
		$stderr = $res->{error_message} // "";
		die "error: status = $status stderr: '$stderr'\nwhile running '$sql'"
		  if ($status != 1 && $status != 2); # COMMAND_OK or COMMAND_TUPLES

	}
	else
	{
		# diag "safe_psql call has params or multiple statements";

		my $ret = $self->psql(
			$dbname, $sql,
			%params,
			stdout => \$stdout,
			stderr => \$stderr,
			on_error_die => 1,
			on_error_stop => 1);

		# psql can emit stderr from NOTICEs etc
		if ($stderr ne "")
		{
			print "#### Begin standard error\n";
			print $stderr;
			print "\n#### End standard error\n";
		}
	}


	return $stdout;
}

=pod

=item $node->psql($dbname, $sql, %params) => psql_retval

Invoke B<psql> to execute B<$sql> on B<$dbname> and return the return value
from B<psql>, which is run with on_error_stop by default so that it will
stop running sql and return 3 if the passed SQL results in an error.

As a convenience, if B<psql> is called in array context it returns an
array containing ($retval, $stdout, $stderr).

psql is invoked in tuples-only unaligned mode with reading of B<.psqlrc>
disabled.  That may be overridden by passing extra psql parameters.

stdout and stderr are transformed to UNIX line endings if on Windows. Any
trailing newline is removed.

Dies on failure to invoke psql but not if psql exits with a nonzero
return code (unless on_error_die specified).

If psql exits because of a signal, an exception is raised.

=over

=item stdout => \$stdout

B<stdout>, if given, must be a scalar reference to which standard output is
written.  If not given, standard output is not redirected and will be printed
unless B<psql> is called in array context, in which case it's captured and
returned.

=item stderr => \$stderr

Same as B<stdout> but gets standard error. If the same scalar is passed for
both B<stdout> and B<stderr> the results may be interleaved unpredictably.

=item on_error_stop => 1

By default, the B<psql> method invokes the B<psql> program with ON_ERROR_STOP=1
set, so SQL execution is stopped at the first error and exit code 3 is
returned.  Set B<on_error_stop> to 0 to ignore errors instead.

=item on_error_die => 0

By default, this method returns psql's result code. Pass on_error_die to
instead die with an informative message.

=item timeout => 'interval'

Set a timeout for the psql call as an interval accepted by B<IPC::Run::timer>
(integer seconds is fine).  This method raises an exception on timeout, unless
the B<timed_out> parameter is also given.

=item timed_out => \$timed_out

If B<timeout> is set and this parameter is given, the scalar it references
is set to true if the psql call times out.

=item connstr => B<value>

If set, use this as the connection string for the connection to the
backend.

=item replication => B<value>

If set, add B<replication=value> to the conninfo string.
Passing the literal value C<database> results in a logical replication
connection.

=item extra_params => ['--single-transaction']

If given, it must be an array reference containing additional parameters to B<psql>.

=back

e.g.

	my ($stdout, $stderr, $timed_out);
	my $cmdret = $node->psql('postgres', 'SELECT pg_sleep(600)',
		stdout => \$stdout, stderr => \$stderr,
		timeout => $PostgreSQL::Test::Utils::timeout_default,
		timed_out => \$timed_out,
		extra_params => ['--single-transaction'])

will set $cmdret to undef and $timed_out to a true value.

	$node->psql('postgres', $sql, on_error_die => 1);

dies with an informative message if $sql fails.

=cut

sub psql
{
	my ($self, $dbname, $sql, %params) = @_;

	my $stdout = $params{stdout};
	my $stderr = $params{stderr};
	my $timeout = undef;
	my $timeout_exception = 'psql timed out';

	# Build the connection string.
	my $psql_connstr;
	if (defined $params{connstr})
	{
		$psql_connstr = $params{connstr};
	}
	else
	{
		$psql_connstr = $self->connstr($dbname);
	}

	my @psql_params = (
		'psql',
		'-XAtq', '-d', $psql_connstr, '-f', '-');

	# If the caller wants an array and hasn't passed stdout/stderr
	# references, allocate temporary ones to capture them so we
	# can return them. Otherwise we won't redirect them at all.
	if (wantarray)
	{
		if (!defined($stdout))
		{
			my $temp_stdout = "";
			$stdout = \$temp_stdout;
		}
		if (!defined($stderr))
		{
			my $temp_stderr = "";
			$stderr = \$temp_stderr;
		}
	}

	$params{on_error_stop} = 1 unless defined $params{on_error_stop};
	$params{on_error_die} = 0 unless defined $params{on_error_die};

	push @psql_params, '-v', 'ON_ERROR_STOP=1' if $params{on_error_stop};
	push @psql_params, @{ $params{extra_params} }
	  if defined $params{extra_params};

	$timeout =
	  IPC::Run::timeout($params{timeout}, exception => $timeout_exception)
	  if (defined($params{timeout}));

	${ $params{timed_out} } = 0 if defined $params{timed_out};

	# IPC::Run would otherwise append to existing contents:
	$$stdout = "" if ref($stdout);
	$$stderr = "" if ref($stderr);

	my $ret;

	# Run psql and capture any possible exceptions.  If the exception is
	# because of a timeout and the caller requested to handle that, just return
	# and set the flag.  Otherwise, and for any other exception, rethrow.
	#
	# For background, see
	# https://metacpan.org/release/ETHER/Try-Tiny-0.24/view/lib/Try/Tiny.pm
	do
	{
		local $@;
		eval {
			my @ipcrun_opts = (\@psql_params, '<', \$sql);
			push @ipcrun_opts, '>', $stdout if defined $stdout;
			push @ipcrun_opts, '2>', $stderr if defined $stderr;
			push @ipcrun_opts, $timeout if defined $timeout;

			IPC::Run::run @ipcrun_opts;
			$ret = $?;
		};
		my $exc_save = $@;
		if ($exc_save)
		{

			# IPC::Run::run threw an exception. re-throw unless it's a
			# timeout, which we'll handle by testing is_expired
			die $exc_save
			  if (blessed($exc_save)
				|| $exc_save !~ /^\Q$timeout_exception\E/);

			$ret = undef;

			die "Got timeout exception '$exc_save' but timer not expired?!"
			  unless $timeout->is_expired;

			if (defined($params{timed_out}))
			{
				${ $params{timed_out} } = 1;
			}
			else
			{
				die "psql timed out: stderr: '$$stderr'\n"
				  . "while running '@psql_params'";
			}
		}
	};

	if (defined $$stdout)
	{
		chomp $$stdout;
	}

	if (defined $$stderr)
	{
		chomp $$stderr;
	}

	# See http://perldoc.perl.org/perlvar.html#%24CHILD_ERROR
	# We don't use IPC::Run::Simple to limit dependencies.
	#
	# We always die on signal.
	if (defined $ret)
	{
		my $core = $ret & 128 ? " (core dumped)" : "";
		die "psql exited with signal "
		  . ($ret & 127)
		  . "$core: '$$stderr' while running '@psql_params'"
		  if $ret & 127;
		$ret = $ret >> 8;
	}

	if ($ret && $params{on_error_die})
	{
		die "psql error: stderr: '$$stderr'\nwhile running '@psql_params'"
		  if $ret == 1;
		die "connection error: '$$stderr'\nwhile running '@psql_params'"
		  if $ret == 2;
		die
		  "error running SQL: '$$stderr'\nwhile running '@psql_params' with sql '$sql'"
		  if $ret == 3;
		die "psql returns $ret: '$$stderr'\nwhile running '@psql_params'";
	}

	if (wantarray)
	{
		return ($ret, $$stdout, $$stderr);
	}
	else
	{
		return $ret;
	}
}


=pod

=item $node->poll_query_until($dbname, $query [, $expected ])

Run B<$query> repeatedly, until it returns the B<$expected> result
('t', or SQL boolean true, by default).
Continues polling if B<psql> returns an error result.
Times out after $PostgreSQL::Test::Utils::timeout_default seconds.
Returns 1 if successful, 0 if timed out.

=cut

sub poll_query_until
{
	my ($self, $dbname, $query, $expected) = @_;

	$expected //= 't';

	my $session = PostgreSQL::Test::Session->new(
		connstr => $self->connstr($dbname));

	my $max_attempts = 10 * $PostgreSQL::Test::Utils::timeout_default;
	my $attempts = 0;

	my $query_value;

	while ($attempts < $max_attempts)
	{
		my $result = $session->query($query);
		$query_value = ($result->{psqlout} // "");
		return 1 if  $query_value eq $expected;

		# Wait 0.1 second before retrying.
		usleep(100_000);

		$attempts++;
	}

	# Give up. Print the output from the last attempt, hopefully that's useful
	# for debugging.
	diag qq(poll_query_until timed out executing this query:
$query
expecting this output:
$expected
last actual query output:
$query_value
);

    return 0;
}

=pod

=item $node->poll_until_connection($dbname)

Try to connect repeatedly, until it we succeed.
Times out after $PostgreSQL::Test::Utils::timeout_default seconds.
Returns 1 if successful, 0 if timed out.

=cut

sub poll_until_connection
{
	my ($self, $dbname) = @_;

	my $max_attempts = 10 * $PostgreSQL::Test::Utils::timeout_default;
	my $attempts = 0;

	while ($attempts < $max_attempts)
	{
		my $session = PostgreSQL::Test::Session->new(
			connstr => $self->connstr($dbname));

		return 1 if $session;

		# Wait 0.1 second before retrying.
		usleep(100_000);

		$attempts++;
	}

	return 0;
}

=pod

=back

=cut


1;
