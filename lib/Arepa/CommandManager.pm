package Arepa::CommandManager;

use strict;
use warnings;

use File::Path;
use File::Temp;

use Arepa::BuilderFarm;
use Arepa::Repository;
use Arepa::Builder;

my $ui_module = 'Arepa::UI::Text';

sub ui_module {
    my ($self, $module) = @_;

    Arepa::Builder->ui_module($module);
    if (defined $module) {
        $ui_module = $module;
    }
    eval qq(use $ui_module;);
    die $@ if $@;
    return $ui_module;
}

sub print {
    my ($self, @args) = @_;
    $self->ui_module->print(@args);
}

sub new {
    my ($class, $config_file) = @_;

    return bless {
                   config_file => $config_file,
                   farm        => Arepa::BuilderFarm->new($config_file),
                   repository  => Arepa::Repository->new($config_file),
                 },
                 $class;
}

sub _farm       { $_[0]->{farm} }
sub _repository { $_[0]->{repository} }

sub build_pending {
    my ($self) = @_;

    my @pending_queue = $self->_farm->package_db->
                               get_compilation_queue(status => 'pending');
    foreach my $req (@pending_queue) {
        # Just get the first one if there are multiple matches
        my ($builder) = $self->_farm->
                               get_matching_builders($req->{architecture},
                                                     $req->{distribution});
        if (!defined $builder) {
            print STDERR "There aren't any builders for $req->{distribution}/$req->{architecture}???\n";
            exit 1;
        }
        my $source_pkg_id = $req->{source_package_id};
        my %source_attrs  = $self->_farm->package_db->
                                   get_source_package_by_id($source_pkg_id);
        $self->print("Compiling request id $req->{id}\n");
        $self->print("$source_attrs{name} $source_attrs{full_version} ");
        $self->print("(arch: $req->{architecture}, ");
        $self->print("distro: $req->{distribution}) ");
        $self->print("with builder $builder...\n");
        my $temp_dir = File::Temp::tempdir();
        if ($self->_farm->compile_package_from_queue($builder,
                                                     $req->{id},
                                                     output_dir => $temp_dir)) {
            $self->print("*** SUCCESS ***\n");
            foreach my $deb_package (glob("$temp_dir/*.deb")) {
                $self->print("Adding $deb_package to the repository\n");
                if ($self->_repository->
                           insert_binary_package($deb_package,
                                                 $req->{distribution})) {
                    unlink $deb_package;
                }
            }
            $self->_repository->sign_distribution($req->{distribution});
        }
        else {
            $self->print("*** FAILED ***\n");
        }
        rmtree($temp_dir);
    }
}

sub recompile_request {
    my ($self, $request_id) = @_;

    my %req = $self->_farm->package_db->
                            get_compilation_request_by_id($request_id);

    # Find out the builder for this compilation. If it's not claimed by any
    # builder, get the first matching (there should be only one, really)
    my $builder = $req{builder};
    if (!$builder) {
        ($builder) = $self->_farm->get_matching_builders($req{architecture},
                                                         $req{distribution});
    }

    my %source_attrs = $self->_farm->package_db->
                              get_source_package_by_id($req{source_package_id});
    $self->print("Compiling request id $req{id}\n");
    $self->print("$source_attrs{name} ");
    $self->print("$source_attrs{full_version} ");
    $self->print("(arch: $req{architecture}, ");
    $self->print("distro: $req{distribution}) ");
    $self->print("with builder $builder...\n");
    my $temp_dir = File::Temp::tempdir();
    if ($self->_farm->compile_package_from_queue($builder,
                                          $req{id},
                                          output_dir => $temp_dir)) {
        $self->print(" done.\n");
        foreach my $deb_package (glob('*.deb')) {
            $self->print("Adding $deb_package to the repository\n");
            if ($self->_repository->
                       insert_binary_package($deb_package,
                                             $req{distribution})) {
                unlink $deb_package;
            }
        }
        $self->_repository->sign_distribution($req{distribution});
    }
    else {
        $self->print(" failed.\n");
        $self->print("Log:\n".$self->_farm->last_build_log."\n");
    }
    rmtree($temp_dir);
}

sub build_dsc {
    my ($self, $builder, $dsc_file) = @_;

    my $temp_dir = File::Temp::tempdir();
    $self->_farm->compile_package_from_dsc($builder, $dsc_file,
                                           output_dir => $temp_dir);
    foreach my $deb_package (glob('*.deb')) {
        $self->print("Adding $deb_package to the repository\n");
        if ($self->_repository->insert_binary_package($deb_package)) {
            unlink $deb_package;
        }
    }
    rmtree($temp_dir);
}

sub request_source_pkg_compilation {
    my ($self, $source_pkg, $distro, $arch) = @_;

    my $pkg_db = $self->_farm->package_db;
    my $source_id = $pkg_db->get_source_package_id($source_pkg, '*latest*');
    if ($source_id) {
        my @targets = $self->_farm->get_compilation_targets($source_id);
        if (grep { $_->[0] eq $arch && $_->[1] eq $distro } @targets) {
            $pkg_db->request_compilation($source_id, $arch, $distro);
        }
        else {
            die "Distribution $distro (arch $arch) is not a valid target " .
                "for $source_pkg\n";
        }
    }
    else {
        die "Couldn't find source package $source_pkg\n";
    }
}

1;
