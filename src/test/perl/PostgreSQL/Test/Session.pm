
# Copyright (c) 2021-2024, PostgreSQL Global Development Group

=pod

=head1 NAME

PostgreSQL::Test::Session - class for a PostgreSQL libpq session

=head1 SYNOPSIS

  use PostgreSQL::Test::Session;

  use PostgreSQL::Test::Cluster;

  my $node = PostgreSQL::Test::Cluster->new('mynode');

  # create a new session. defult dbname is 'postgres'
  my $session = PostgreSQL::Test::Session->new(node => $node
                                               [, dbname => $dbname] );

  # close the session
  $session->close;

  # reopen the session, after closing it if not closed
  $session->reconnect;

  # check if the session is ok
  # my $status = $session->conn_status;

  # run some SQL, not producing tuples
  my $result = $session->do($sql, ...);

  # run an SQL statement asynchronously
  my $result = $session->do_async($sql);

  # wait for and async SQL to complete
  $session->wait_for_completion;

  # set a password for a user
  my $result = $session->set_password($user, $password);

  # get some data
  my $result = $session->query($sql);

  # get a single value, default croaks if no value found
  my $val = $session->query_oneval($sql [, $missing_ok ]);

  #return lines of tuples like "psql -A -t"
  my @lines = $session->query_tuples($sql, ...);

=head1 DESCRIPTION

C<PostgreSQL::Test::Session> encapsulates a C<libpq> session for use in
PostgreSQL TAP tests, allowing the test to connect without having to spawn
C<psql> in a child process.

The session object is automatically closed when the object goes out of scope,
including at script end.

Several methods return a hashref as a result, which will have the following
fields:

=over

=item * status

=item * error_message (only if there is an error)

=item * names

=item * types

=item * rows

=item * psqlout

=back

The last 4 will be empty unless the SQL produces tuples.

=cut

package PostgreSQL::Test::Session;

use strict;
use warnings FATAL => 'all';

use File::Basename qw(dirname);
use Carp;
use Time::HiRes qw(usleep);

my $setup_ok;

BEGIN
{
	if ($ENV{PG_USE_PQ_XS})
	{
		# need the directory where Pq.{so,dll,dylib} is installed or built
		# first, if installed it should be alongside this file
		my @dirs = (dirname(__FILE__));
		# second, it should be built here
		my $topbuilddir = $ENV{MESON_BUILD_ROOT} || $ENV{top_builddir};
		push (@dirs, "$topbuilddir/src/test/perl/PostgreSQL/Test")
		  if defined($topbuilddir);
		unshift(@INC, @dirs);
		# this will fail if we haven't built the shared library
		require PostgreSQL::Test::Pq;
		PostgreSQL::Test::Pq->import;
		$setup_ok = 1; # no other setup required.
		# restore @INC
		shift(@INC) foreach @dirs;
	}
	else
	{
		# default is to use the FFI wrapper
		# will fail if the FFI libraries and wrappers are not available
		#
		# actual setup is done per session, because we get the libdir from the
		# node object (in most cases)
		require PostgreSQL::PqFFI;
		PostgreSQL::PqFFI->import;
	}
}

sub _setup
{
	return if $setup_ok;
	my $libdir = shift;
	PostgreSQL::PqFFI::setup($libdir);
	$setup_ok = 1;
}

=pod

=head1 METHODS

=over

=item PostgreSQL::Test::Session->new(node=> $node [, dbname=> $dbname ])

Set up a new session for the node, which must be a C<PostgreSQL::Test::Cluster>
instance. The default dbame is C<postgres>.

=item PostgreSQL::Test::Session->new(connstr => $connstr [, libdir => $libdir])

Set up a new session for the connection string. If using the FFI libpq wrapper,
C<$libdir> must point to the directory where the libpq library is installed.

=cut

sub new
{
	my $class = shift;
	my $self = {};
	bless $self, $class;
	my %args = @_;
	my $node = $args{node};
	my $dbname = $args{dbname} || 'postgres';
	my $libdir = $args{libdir};
	my $connstr = $args{connstr};
	unless ($setup_ok)
	{
		unless ($libdir)
		{
			croak "bad node" unless $node->isa("PostgreSQL::Test::Cluster");
			$libdir = $node->config_data('--libdir');
		}
		_setup($libdir);
	}
	unless ($connstr)
	{
		croak "bad node" unless $node->isa("PostgreSQL::Test::Cluster");
		$connstr = $node->connstr($dbname);
	}
	print STDERR "connstr = $connstr\n";
	$self->{connstr} = $connstr;
	$self->{conn} = PQconnectdb($connstr);
	# The destructor will clean up for us even if we fail
	return (PQstatus($self->{conn}) == CONNECTION_OK) ? $self : undef;
}

=pod

=item $session->close()

Close the connection

=cut

sub close
{
	my $self = shift;
	PQfinish($self->{conn});
	delete $self->{conn};
}

# close the session if the object goes out of scope
sub DESTROY
{
	my $self = shift;
	$self->close if exists $self->{conn};
}

=pod

=item $session->reconnect()

Reopen the session using the original connstr. If the session is still open,
close it before reopening.

=cut

sub reconnect
{
	my $self = shift;
	$self->close if exists $self->{conn};
	$self->{conn} = PQconnectdb($self->{connstr});
	return PQstatus($self->{conn});
}

=pod

=item $session->conn_status()

Return the connection status. This will be a libpq status value like
C<CONNECTION_OK>.

=cut

sub conn_status
{
	my $self = shift;
	return exists $self->{conn} ? PQstatus($self->{conn}) : undef;
}

=pod

=item $session->do($sql, ...)

Run one or more SQL statements synchronously (using C<PQexec>). The statements
should not return any tuples. Returns the status, which will be
C<PGRES_COMMAND_OK> (i.e. 1) in the case of success.

=cut

sub do
{
	my $self = shift;
	my $conn = $self->{conn};
	my $status;
	foreach my $sql (@_)
	{
		my $result = PQexec($conn, $sql);
		$status = PQresultStatus($result);
		PQclear($result);
		return $status unless $status == PGRES_COMMAND_OK;
	}
	return $status;
}

=pod

=item $session->do_async($sql)

Run a single statement asynchronously, using C<PQsendQuery>. The return value
is a boolean indicating success.

=cut

sub do_async
{
	my $self = shift;
	my $conn = $self->{conn};
	my $sql = shift;
	my $result = PQsendQuery($conn, $sql);
	return $result; # 1 or 0
}

# get the next resultset from some aync commands
# wait if necessary
# c.f. libpqsrv_get_result
sub _get_result
{
	my $conn = shift;
	while (PQisBusy($conn))
	{
		usleep(100_000);
		last if PQconsumeInput($conn) == 0;
	}
	return PQgetResult($conn);
}

=pod

=item $session->wait_for_completion()

Wait until all asynchronous SQL has completed

=cut

sub wait_for_completion
{
	# wait for all the resultsets and clear them
	# c.f. libpqsrv_get_result_last
	my $self = shift;
	my $conn = $self->{conn};
	while (my $res = _get_result($conn))
	{
		PQclear($res);
	}
}

=pod

=item  $session->set_password($user, $password)

Set the user's password by calling C<PQchangePassword>.

Returns a result hash.

=cut

# set password for user
sub set_password
{
	my $self = shift;
	my $user = shift;
	my $password = shift;
	my $conn = $self->{conn};
	my $result = PQchangePassword($conn, $user, $password);
	my $ret = _get_result_data($result);
	PQclear($result);
	return $ret;
}

# Common internal routine to process result data.
# The returned object is dead and will be garbage collected as necessary.

sub _get_result_data
{
	my $result = shift;
	my $conn = shift;
	my $status = PQresultStatus($result);
	my $res = {	status => $status, names => [], types => [], rows => [],
			psqlout => ""};
	unless ($status == PGRES_TUPLES_OK || $status == PGRES_COMMAND_OK)
	{
		$res->{error_message} = PQerrorMessage($conn);
		return $res;
	}
	if ($status == PGRES_COMMAND_OK)
	{
		return $res;
	}
	my $ntuples = PQntuples($result);
	my $nfields = PQnfields($result);
	# assuming here that the strings returned by PQfname and PQgetvalue
	# are mapped into perl space using setsvpv or similar and thus won't
	# be affect by us calling PQclear on the result object.
	foreach my $field (0 .. $nfields-1)
	{
		push(@{$res->{names}}, PQfname($result, $field));
		push(@{$res->{types}}, PQftype($result, $field));
	}
	my @textrows;
	foreach my $nrow (0 .. $ntuples - 1)
	{
		my $row = [];
		foreach my $field ( 0 .. $nfields - 1)
		{
			my $val = PQgetvalue($result, $nrow, $field);
			if (($val // "") eq "")
			{
				$val = undef if PQgetisnull($result, $nrow, $field);
			}
			push(@$row, $val);
		}
		push(@{$res->{rows}}, $row);
		no warnings qw(uninitialized);
		push(@textrows, join('|', @$row));
	}
	$res->{psqlout} = join("\n",@textrows) if $ntuples;
	return $res;
}


=pod

=item $session->query($sql)

Runs sql that might return tuples.

Returns a result hash.

=cut



sub query
{
	my $self = shift;
	my $sql = shift;
	my $conn = $self->{conn};
	my $result = PQexec($conn, $sql);
	my $res = _get_result_data($result, $conn);
	PQclear($result);
	return $res;
}

=pod

=item $session->query_oneval($sql [, $missing_ok ] )

Run a query that is expected to return no more than one tuple with one value;

If C<$missing_ok> is true, return undef if the query returns no tuple. Otherwise
croak if there is not exactly one tuple, or of the tuple does not have
exctly one value.

If none of these apply, return the single value from the query. A NULL value
will result in undef, so if C<$missing_ok> is true you won't be able to
distinguish between a null value and a missing tuple.

A non NULL value is returned as the string value obtained from C<PQgetvalue>.

=cut

sub query_oneval
{
	my $self = shift;
	my $sql = shift;
	my $missing_ok = shift; # default is not ok
	my $conn = $self->{conn};
	my $result = PQexec($conn, $sql);
	my $status = PQresultStatus($result);
	unless  ($status == PGRES_TUPLES_OK)
	{
		PQclear($result) if $result;
		croak PQerrorMessage($conn);
	}
	my $ntuples = PQntuples($result);
	return undef if ($missing_ok && !$ntuples);
	my $nfields = PQnfields($result);
	croak "$ntuples tuples != 1 or $nfields fields != 1"
	  if $ntuples != 1 || $nfields != 1;
	my $val = PQgetvalue($result, 0, 0);
	if ($val eq "")
	{
		$val = undef if PQgetisnull($result, 0, 0);
	}
	PQclear($result);
	return $val;
}

=pod

=item $session->query_tuples($sql, ...)

Run the sql commands and return the output as a single piece of text in the
same format as C<psql -A -t>.

Fields within tuples are separated by a "|", tuples are spearated by "\n"

=cut

sub query_tuples
{
	my $self = shift;
	my @results;
	foreach my $sql (@_)
	{
		my $res = $self->query($sql);
		croak $res->{error_message}
		  unless $res->{status} == PGRES_TUPLES_OK;
		my $rows = $res->{rows};
		unless (@$rows)
		{
			# unfortunately breaks at least one test
			# push(@results,"-- empty");
			next;
		}
		# join will render undef as an empty string here
		no warnings qw(uninitialized);
		my @tuples = map { join('|', @$_); } @$rows;
		push(@results, join("\n",@tuples));
	}
	return join("\n",@results);
}

=pod

=back

=cut


1;
