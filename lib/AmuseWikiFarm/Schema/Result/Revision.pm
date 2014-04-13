use utf8;
package AmuseWikiFarm::Schema::Result::Revision;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

AmuseWikiFarm::Schema::Result::Revision

=cut

use strict;
use warnings;

use Moose;
use MooseX::NonMoose;
use MooseX::MarkAsMethods autoclean => 1;
extends 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<revision>

=cut

__PACKAGE__->table("revision");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 site_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 0
  size: 8

=head2 title_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 f_full_path_name

  data_type: 'text'
  is_nullable: 1

=head2 status

  data_type: 'varchar'
  default_value: 'editing'
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 updated

  data_type: 'datetime'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "site_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 0, size => 8 },
  "title_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "f_full_path_name",
  { data_type => "text", is_nullable => 1 },
  "status",
  {
    data_type => "varchar",
    default_value => "editing",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "updated",
  { data_type => "datetime", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 site

Type: belongs_to

Related object: L<AmuseWikiFarm::Schema::Result::Site>

=cut

__PACKAGE__->belongs_to(
  "site",
  "AmuseWikiFarm::Schema::Result::Site",
  { id => "site_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 title

Type: belongs_to

Related object: L<AmuseWikiFarm::Schema::Result::Title>

=cut

__PACKAGE__->belongs_to(
  "title",
  "AmuseWikiFarm::Schema::Result::Title",
  { id => "title_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07039 @ 2014-03-27 15:53:08
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:MK51pOugupyd9sIvAvi2qw

# core modules
use File::Basename qw/fileparse/;
use File::Spec;
use File::Copy qw/copy move/;
use Digest::SHA;

use File::Slurp qw/read_file/;
use File::MimeInfo::Magic qw/mimetype/;
use Text::Amuse;
use AmuseWikiFarm::Utils::Amuse qw/muse_get_full_path
                                   muse_parse_file_path
                                   muse_naming_algo/;


=head2 muse_body

Return the text stored in the staging area (for editing)

=head2 muse_doc

Return a L<Text::Amuse> object for that file.

=cut

sub muse_body  {
    my $self = shift;
    my $file = $self->f_full_path_name;
    return '' unless -f $file;
    my $body = read_file($file => { binmode => ':encoding(utf-8)' });
    return $body;
}

sub muse_doc {
    my $self = shift;
    my $file = $self->f_full_path_name;
    return '' unless -f $file;
    my $doc = Text::Amuse->new(file => $file);
    return $doc;
}

sub file_parsing {
    my ($self, $type) = @_;
    my ($name, $path, $suffix) = fileparse($self->f_full_path_name, '.muse');
    if ($type eq 'dir') {
        return $path;
    }
    elsif ($type eq 'name') {
        return $name;
    }
}

sub muse_uri {
    return shift->file_parsing('name');
}

sub working_dir {
    return shift->file_parsing('dir');
}

=head2 private files

They have an underscore, so they are invalid files for use and avoid clashes.
They are pretty much internals

=over 4

=item starting_file

=item original_html

=item temporary_file

Temporary file

=item aux_file

Auxiliary file

=back

=cut

sub starting_file {
    my $self = shift;
    return File::Spec->catfile($self->working_dir, 'private_orig.muse');
}

sub original_html {
    my $self = shift;
    return File::Spec->catfile($self->working_dir, 'private_orig.html');
}

sub temporary_file {
    my $self = shift;
    return File::Spec->catfile($self->working_dir, 'private_tmp.muse');
}

sub aux_file {
    my $self = shift;
    return File::Spec->catfile($self->working_dir, 'private_aux.muse');
}

=head2 attached_files

Return an array reference to the list of attached basenames.

=cut

sub attached_files {
    my $self = shift;
    my @files;
    my $dir = $self->working_dir;
    opendir(my $dh, $dir) || die "can't opendir $dir: $!";
    # we know only about pdf, jpeg, png
    @files = grep { /\w\.(pdf|jpe?g|png)$/ && -f File::Spec->catfile($dir, $_) }
      readdir($dh);
    closedir $dh;
    return \@files;
}

sub attached_file_path {
    my ($self, $name) = @_;
    return unless $name;
    my $path = File::Spec->catfile($self->working_dir, $name);
    return unless -f $path;
    return $path;
}

=head2 attached_files_paths

Return a list of absolute path to the attached files.

=cut


sub attached_files_paths {
    my $self = shift;
    my @paths;
    foreach my $file (@{$self->attached_files}) {
        my $path = $self->attached_file_path($file);
        push @paths, $path if $path;
    }
    return @paths;
}


=head2 edit(\$string)

Edit the current revision. It's reccomended to pass a reference to a
scalar or an hashref with the string in the "body" key to avoid large
copying, but a scalar will do the same.

=cut

sub edit {
    my ($self, $string) = @_;
    die "Missing argument" unless $string;

    my $target   = $self->f_full_path_name;
    my $original = $self->starting_file;
    my $temp     = $self->temporary_file;
    my $aux      = $self->aux_file;
    # check if we have the main file
    die "Can't edit a non-existent file!" unless -f $target;

    # assert that we have the starting point file
    unless (-f $original) {
        copy($target, $original) or die "Couldn't copy $target to $original $!";
    }

    my $is_ref = ref($string);

    # before overwriting, we do some mambo-jumbo to strip out \r

    # save the parameter in the temporary file
    open (my $fh, '>:encoding(utf-8)', $temp) or die "Fail to open $temp $!";
    if ($is_ref eq 'SCALAR') {
        print $fh $$string;
    }
    elsif ($is_ref eq 'HASH' and exists $string->{body}) {
        print $fh $string->{body};
    }
    elsif (!$is_ref) {
        print $fh $string;
    }
    else {
        die "Failed to write string, bad usage!";
    }
    close $fh or die "Fail to close $temp $!";

    # then filter it and write to an aux
    open (my $tmpfh, '<:encoding(utf-8)', $temp) or die "Can't open $temp $!";
    open (my $auxfh, '>:encoding(utf-8)', $aux) or die "Can't open $aux $!";

    # TODO this is the good place to use the filters, not modifying the params
    my $current;
    while (<$tmpfh>) {
        s/\r//;
        s/\t/    /;
        print $auxfh $_;
        $current = $_;
    }
    # last line
    if ($current !~ /\n$/s) {
        print $auxfh "\n";
    }
    close $auxfh or die $!;
    close $tmpfh or die $!;
    move($aux, $target) or die "Couldn't move $aux to $target";
    # finally move it to the target file
}

=head2 add_attachment($filename)

Given the filename as first argument, copy it into the working
directory, taking care of not overwrite anything. Return 0 on success,
the error otherwise.

=cut

sub add_attachment {
    my ($self, $filename) = @_;
    die "Missing argument" unless $filename;
    return "$filename doesn't exist" unless -f $filename;
    my $mime = mimetype($filename) || "";
    my $ext;
    if ($mime eq 'image/jpeg') {
        $ext = '.jpg';
    }
    elsif ($mime eq 'image/png') {
        $ext = '.png';
    }
    # TODO
    # the destination of the pdf attachment should be out of text tree
    # to avoid silly overwriting. After all, we don't embed pdf in
    # html or tex.
    elsif ($mime eq 'application/pdf') {
        $ext = '.pdf';
    }
    else {
        return "Unsupported file type $mime";
    }
    my $pieces = muse_get_full_path($self->muse_uri);
    unless ($pieces && @$pieces) {
        return "Couldn't parse the filename... this is a bug";
    }
    # create a new filename
    my $full = join('-', @$pieces);
    my $base = muse_naming_algo(substr(join('-', @$pieces), 0, 50));
    my $suffix = 0;
    # and now we have to check if the same name exists in the
    # attachment table for the same site.
    my $name;
    do {
        $name = $base . '-' . ++$suffix . $ext;
    } while ($self->site->attachments->find({ uri => $name }));

    die "Something went wrong" unless $name;

    # copy it in the working directory
    my $target = File::Spec->catfile($self->working_dir, $name);
    copy($filename, $target) or die "Couldn't copy $filename to $target $!";

    # and finally insert the thing in the db
    my $info = muse_parse_file_path($target, 1);
    return "Couldn't retrieve info from $target" unless $info;

    $info->{uri} = $info->{f_name} . $info->{f_suffix};

    # and let it crash on race conditions
    $self->site->attachments->create($info);

    return 0;
}

sub destination_paths {
    my $self = shift;
    my $target_dir = $self->site->path_for_file($self->muse_uri);
    return unless $target_dir && -d $target_dir;
    my %dests;
    foreach my $file ($self->f_full_path_name, $self->attached_files_paths) {
        my ($basename, $path) = fileparse($file);
        $dests{$file} = File::Spec->catfile($target_dir, $basename);
    }
    return %dests;
}

=head1 STATUSES

The C<status> column determines the status of a revision. The valid
statuses are:

=over 4

=item editing

The default. The revision has not been committed yet and should be
left alone.

=item pending

The revision has been committed and is ready to be published.

=item published

The revision has been published and can be ignored.

=item processing

The revision has been given to the job server and is under processing.

=item conflict

The revision couldn't be published because couldn't be merged cleanly,
i.e., it would have overwritten some other change.

=back

Each of them are methods you can call and return true when the status
matches. You don't set them directly.

=cut

sub editing {
    shift->status eq 'editing' ? return 1 : return 0;
}

sub pending {
    shift->status eq 'pending' ? return 1 : return 0;
}

sub published {
    shift->status eq 'published' ? return 1 : return 0;
}

sub conflict {
    shift->status eq 'conflict' ? return 1 : return 0;
}

sub processing {
    shift->status eq 'processing' ? return 1 : return 0;
}


=head2 can_be_merged

Calling this method will trigger the SHA1 checksum on the
original_file and the target file. If they don't match, it means that
the revision would overwrite something.

=cut

sub can_be_merged {
    my $self = shift;

    my $destination = $self->title->f_full_path_name;
    my $source = $self->starting_file;

    # will not merge, source doesn't exists, strange enough
    die "No starting file, this is a bug"  unless ($source and -f $source);

    if ($destination and -f $destination) {
        my $src_sha = Digest::SHA->new('SHA-1')->addfile($source);
        my $dst_sha = Digest::SHA->new('SHA-1')->addfile($destination);
        return $src_sha->hexdigest eq $dst_sha->hexdigest;
    }
    else {
        # no destination? nothing to do, will merge cleanly
        return 1;
    }
}



__PACKAGE__->meta->make_immutable;
1;
