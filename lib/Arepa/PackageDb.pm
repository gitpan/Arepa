package Arepa::PackageDb;

use Carp qw(croak);
use DBI;

use constant SOURCE_PACKAGE_FIELDS => qw(name full_version
                                         architecture distribution
                                         comments);
use constant COMPILATION_QUEUE_FIELDS => qw(source_package_id architecture
                                            distribution builder
                                            status compilation_requested_at
                                            compilation_started_at
                                            compilation_completed_at);

sub new {
    my ($class, $path) = @_;

    # See if the DB was there before connecting, so we know if we have to
    # create the table structure
    my $create_tables = 0;
    if (-z $path || ! -e $path) {
        $create_tables = 1;
    }

    my $self = bless {
        path => $path,
        dbh  => DBI->connect("dbi:SQLite:dbname=$path"),
    }, $class;

    if ($create_tables) {
        $self->create_db;
    }

    return $self;
}

sub create_db {
    my ($self) = @_;
    my $r;

    $r = $self->_dbh->do(<<EOSQL);
CREATE TABLE source_packages (id           INTEGER PRIMARY KEY,
                              name         VARCHAR(50),
                              full_version VARCHAR(20),
                              architecture VARCHAR(10),
                              distribution VARCHAR(30),
                              comments     TEXT);
EOSQL
    if (!$r) {
        croak "Couldn't create table 'source_packages' in $self->{path}";
    }

    $r = $self->_dbh->do(<<EOSQL);
CREATE TABLE compilation_queue (id                       INTEGER PRIMARY KEY,
                                source_package_id        INTEGER,
                                architecture             VARCHAR(10),
                                distribution             VARCHAR(30),
                                builder                  VARCHAR(50),
                                status                   VARCHAR(20),
                                compilation_requested_at TIMESTAMP,
                                compilation_started_at   TIMESTAMP,
                                compilation_completed_at TIMESTAMP);
EOSQL
    if (!$r) {
        croak "Couldn't create table 'compilation_queue' in $self->{path}";
    }
}

sub default_timestamp {
    my ($self) = @_;

    my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
    return sprintf("%i-%02i-%02i %02i:%02i:%02i",
                   $year+1900, $mon+1, $mday, $hour, $min, $sec);
}

sub _dbh {
    my ($self) = @_;
    return $self->{dbh};
}

sub get_source_package_id {
    my ($self, $name, $full_version) = @_;

    my $sth = $self->_dbh->prepare("SELECT id FROM source_packages
                                             WHERE name = ?
                                               AND full_version = ?");
    $sth->execute($name, $full_version);
    $sth->bind_columns(\my $id);
    return $sth->fetch ? $id : undef;
}

sub get_source_package_by_id {
    my ($self, $id) = @_;

    my $fields = join(", ", SOURCE_PACKAGE_FIELDS);
    my $sth = $self->_dbh->prepare("SELECT $fields
                                      FROM source_packages
                                     WHERE id = ?");
    $sth->execute($id);
    $sth->bind_columns(\my $name, \my $fv, \my $arch, \my $distro,
                       \my $comments);
    return $sth->fetch ? (id           => $id,
                          name         => $name,
                          full_version => $fv,
                          architecture => $arch,
                          distribution => $distro,
                          comments     => $comments) :
                         croak "Can't find a source package with id '$id'";
}

sub insert_source_package {
    my ($self, %props) = @_;

    my (@fields, @field_values);
    # Check that the props are valid
    foreach my $field (keys %props) {
        if (not grep { $_ eq $field } SOURCE_PACKAGE_FIELDS) {
            croak "Don't recognise field '$field'";
        }
    }
    # Check that at least we have 'name' and 'full_version'
    if (!defined $props{name} || !defined $props{full_version}) {
        croak "At least 'name' and 'full_version' are needed in a source package\n";
    }

    my $id = $self->get_source_package_id($props{name},
                                          $props{full_version});
    if (defined $id) {
        return $id;
    }
    else {
        my $sth = $self->_dbh->prepare("INSERT INTO source_packages (" .
                                            join(", ", keys %props) .
                                            ") VALUES (" .
                                            join(", ", map { "?" }
                                                           keys %props) .
                                            ")");
        if ($sth->execute(values %props)) {
            return $self->_dbh->last_insert_id(undef, undef,
                                               qw(source_packages), undef);
        }
        else {
            print STDERR "ERROR: SQL query failed: ", $self->_dbh->errstr, "\n";
            return 0;
        }
    }
}

sub request_compilation {
    my ($self, $source_id, $arch, $dist, $tstamp) = @_;
    $tstamp ||= $self->default_timestamp;

    # Check that the source package id is valid. We are not going to use the
    # returned value for anything, but it will die with an exception if the id
    # is not valid
    my %source_package = $self->get_source_package_by_id($source_id);

    my $sth = $self->_dbh->prepare("INSERT INTO compilation_queue (
                                                source_package_id,
                                                architecture,
                                                distribution,
                                                status,
                                                compilation_requested_at)
                                        VALUES (?, ?, ?, ?, ?)");
    $sth->execute($source_id, $arch, $dist, "pending", $tstamp);
}

sub get_compilation_queue {
    my ($self, %user_opts) = @_;
    my %opts = (order => "compilation_requested_at", %user_opts);

    my $fields = join(", ", COMPILATION_QUEUE_FIELDS);
    my ($condition, $limit) = ("", "");
    if (exists $opts{status}) {
        $condition = "WHERE status = " . $self->_dbh->quote($opts{status});
    }
    if (exists $opts{limit}) {
        $limit = "LIMIT " . $self->_dbh->quote($opts{limit});
    }
    my $sth = $self->_dbh->prepare("SELECT id, $fields
                                      FROM compilation_queue
                                           $condition
                                  ORDER BY $opts{order}
                                           $limit");
    $sth->execute;
    $sth->bind_columns(\my $id,
                       \my $source_id,  \my $arch,         \my $distro,
                       \my $builder,    \my $stat,         \my $requested_at,
                       \my $started_at, \my $completed_at);
    my @queue = ();
    while ($sth->fetch) {
        push @queue, {id                       => $id,
                      source_package_id        => $source_id,
                      architecture             => $arch,
                      distribution             => $distro,
                      builder                  => $builder,
                      status                   => $stat,
                      compilation_requested_at => $requested_at,
                      compilation_started_at   => $started_at,
                      compilation_completed_at => $completed_at}
    }
    return @queue;
}

sub get_compilation_request_by_id {
    my ($self, $compilation_id) = @_;

    my $fields = join(", ", COMPILATION_QUEUE_FIELDS);
    my $sth = $self->_dbh->prepare("SELECT $fields
                                      FROM compilation_queue
                                     WHERE id = ?");
    $sth->execute($compilation_id);
    $sth->bind_columns(\my $source_id,  \my $arch,         \my $distro,
                       \my $builder,    \my $stat,         \my $requested_at,
                       \my $started_at, \my $completed_at);
    my @queue = ();
    if ($sth->fetch) {
        $sth->finish;
        return (id                       => $compilation_id,
                source_package_id        => $source_id,
                architecture             => $arch,
                distribution             => $distro,
                builder                  => $builder,
                status                   => $stat,
                compilation_requested_at => $requested_at,
                compilation_started_at   => $started_at,
                compilation_completed_at => $completed_at);
    }
    else {
        croak "Can't find any compilation request with id '$compilation_id'";
    }
}

sub _set_compilation_status {
    my ($self, $status, $compilation_id, $tstamp) = @_;
    $tstamp ||= $self->default_timestamp;

    my $sth = $self->_dbh->prepare("UPDATE compilation_queue
                                       SET status                   = ?,
                                           compilation_completed_at = ?
                                     WHERE id = ?");
    $sth->execute($status, $tstamp, $compilation_id);
}

sub mark_compilation_started {
    my ($self, $compilation_id, $builder, $tstamp) = @_;
    my $sth = $self->_dbh->prepare("UPDATE compilation_queue
                                       SET status                 = ?,
                                           builder                = ?,
                                           compilation_started_at = ?
                                     WHERE id = ?");
    $sth->execute('compiling', $builder, $tstamp, $compilation_id);
}

sub mark_compilation_completed {
    my ($self, $compilation_id, $tstamp) = @_;
    $self->_set_compilation_status('compiled', $compilation_id, $tstamp);
}

sub mark_compilation_failed {
    my ($self, $compilation_id, $tstamp) = @_;
    $self->_set_compilation_status('compilationfailed',
                                   $compilation_id, $tstamp);
}

sub mark_compilation_pending {
    my ($self, $compilation_id, $tstamp) = @_;
    $self->_set_compilation_status('pending', $compilation_id, $tstamp);
}

1;

__END__

=head1 NAME

Arepa::PackageDb - Arepa package database API

=head1 SYNOPSIS

 my $pdb = Arepa::PackageDb->new('path/to/packages.db');
 %attrs = (name         => 'dhelp',
           full_version => '0.6.17',
           architecture => 'all',
           distribution => 'unstable');
 my $id = $package_db->insert_source_package(%attrs);
 my $id2 = $package_db->get_source_package_id($name,
                                              $full_version);
 my %source_package = $package_db->get_source_package_by_id($id);

 $pdb->request_compilation($source_id,
                           $arch,
                           $distribution);

 @queue        = $pdb->get_compilation_queue;
 @latest_queue = $pdb->get_compilation_queue(limit => 5);
 @pending_queue   = $pdb->get_compilation_queue(status => 'pending');
 @compiling_queue = $pdb->get_compilation_queue(status => 'compiling');

 my %compilation_attrs = $pdb->get_compilation_request_by_id($id);

 $pdb->mark_compilation_started($compilation_id, $builder_name);
 $pdb->mark_compilation_completed($compilation_id);
 $pdb->mark_compilation_failed($compilation_id);
 $pdb->mark_compilation_pending($compilation_id);

=head1 DESCRIPTION

Arepa stores information about the available source packages and the requests
to compile them in an SQLite 3 database. This class gives a standard and
abstract way to access and update the information in that database.

Usually this class shouldn't be used directly, but through
C<Arepa::Repository>, C<Arepa::BuilderFarm> and others.

=head1 METHODS

=over 4

=item new($path)

It creates a new database access object for the database in the given C<$path>.

=item insert_source_package(%attrs)

Inserts a new source package with the given attributes. At least C<name> and
C<full_version> have to be given. If a package with the given C<name> and
C<full_version> already exists, its id is returned and the rest of the
attributes are ignored. Otherwise, the new source package is created and its id
is returned.

=item get_source_package_id($name, $full_version)

Returns the id for the package with C<$name> and C<$full_version>. Returns
C<undef> if there's no package with that name and version.

=item get_source_package_by_id($source_id)

Returns a hash with the attributes for the package with id C<$source_id>. If
the given id doesn't exist, an exception is thrown.

=item request_compilation($source_id, $architecture, $distribution)

Inserts a new compilation request for the given C<$source_id>,
C<$architecture> and C<$distribution>. No checks are made as to ensure that
the given architecture and distribution match the original source package.

=item get_compilation_queue(%options)

Returns a list compilation requests. Each request is a hashref with all the
attributes. By default, all elements in the queue are returned. However,
C<%options> can be used to customise the results: a key C<status> only
returns the requests in the given status; a key C<limit> limits the results to
only as many as specified; a key C<order> tweaks the order (it's plain SQL, so
you can add more than one field and or "DESC" after each one).

=item get_compilation_request_by_id($request_id)

Returns a hash with the attributes of the compilation request with the given
C<$request_id>. If no request with the given id exists, an exception is thrown.

=item mark_compilation_started($request_id, $builder_name)

=item mark_compilation_started($request_id, $builder_name, $timestamp)

Marks the given compilation request as started by the given C<$builder_name>.
If C<$timestamp> is passed, that timestamp is used. Otherwise, the current
time.

=item mark_compilation_completed($request_id)

=item mark_compilation_completed($request_id, $timestamp)

Marks the given compilation request as finished.  If C<$timestamp> is passed,
that timestamp is used. Otherwise, the current time.

=item mark_compilation_failed($request_id)

=item mark_compilation_failed($request_id, $timestamp)

Marks the given compilation request as failed.  If C<$timestamp> is passed,
that timestamp is used. Otherwise, the current time.

=item mark_compilation_pending($request_id)

=item mark_compilation_pending($request_id, $timestamp)

Marks the given compilation request as pending (re-queue, sort of).  If
C<$timestamp> is passed, that timestamp is used. Otherwise, the current time.

=back

=head1 SEE ALSO

C<Arepa::BuilderFarm>, C<Arepa::Repository>.

=head1 AUTHOR

Esteban Manchado Velázquez <estebanm@opera.com>.

=head1 LICENSE AND COPYRIGHT

This code is offered under the Open Source BSD license.

Copyright (c) 2010, Opera Software. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

=over 4

=item

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

=item

Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

=item

Neither the name of Opera Software nor the names of its contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

=back

=head1 DISCLAIMER OF WARRANTY

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.