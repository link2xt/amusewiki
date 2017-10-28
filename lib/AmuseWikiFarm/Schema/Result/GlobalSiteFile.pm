use utf8;
package AmuseWikiFarm::Schema::Result::GlobalSiteFile;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

AmuseWikiFarm::Schema::Result::GlobalSiteFile - Site files

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

=head1 TABLE: C<global_site_files>

=cut

__PACKAGE__->table("global_site_files");

=head1 ACCESSORS

=head2 site_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 file_name

  data_type: 'varchar'
  is_nullable: 0
  size: 64

=head2 file_path

  data_type: 'text'
  is_nullable: 0

=head2 image_width

  data_type: 'integer'
  is_nullable: 1

=head2 image_height

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "site_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "file_name",
  { data_type => "varchar", is_nullable => 0, size => 64 },
  "file_path",
  { data_type => "text", is_nullable => 0 },
  "image_width",
  { data_type => "integer", is_nullable => 1 },
  "image_height",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</site_id>

=item * L</file_name>

=back

=cut

__PACKAGE__->set_primary_key("site_id", "file_name");

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


# Created by DBIx::Class::Schema::Loader v0.07042 @ 2017-10-28 12:36:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2nGD+mCJSUgurVA4fbmmMg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
__PACKAGE__->meta->make_immutable;
1;
