package AmuseWikiFarm::Utils::Amuse;
use utf8;
use strict;
use warnings;

use Data::Dumper;
use File::Spec;
use File::Basename;
use Text::Amuse::Functions qw/muse_fast_scan_header muse_format_line/;
use Text::Amuse::Compile::MuseHeader;
use HTML::Entities qw/decode_entities encode_entities/;
use Encode;
use Digest::MD5 qw/md5_hex/;
use DateTime;
use Date::Parse qw/str2time/;
use Text::Unidecode qw/unidecode/;
use JSON::MaybeXS ();
use Try::Tiny;
use AmuseWikiFarm::Log::Contextual;
use Path::Tiny;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw/muse_file_info
                    muse_naming_algo
                    muse_get_full_path
                    muse_attachment_basename_for
                    muse_parse_file_path
                    muse_filepath_is_valid
                    split_pdf
                    image_dimensions
                    clean_username
                    clean_html
                    to_json
                    from_json
                    amw_meta_stripper
                    cover_filename_is_valid
                    muse_filename_is_valid/;

=head1 NAME

AmuseWikiFarm::Utils::Amuse - amusewiki utilities

=head2 muse_file_info($file, $root)

Scan the header of the file $file, considering its root $root, and
collect all the relevant information, returning them as a hashref. It
includes also the file attributes, like timestamp, paths, etc.

The result is suitable to feed the database, so see
L<AmuseWikiFarm::Schema::Result::Title> for the returned keys and the
AmuseWiki manual for the list of supported and defined directives.

If the file passed is not a muse file, but a jpeg, jpg, png or pdf
file, header is not checked, but the file info are returned, together
with uri, suitable to be inserted in the
L<AmuseWikiFarm::Schema::Result::Attachment> table, or
L<AmuseWikiFarm::Schema::Result::Special> or
L<AmuseWikiFarm::Schema::Result::Specialimage>

Special cases:

LISTtitle in the header will map to C<list_title>, defaulting to
C<title>, where any leading non-word characters are stripped (which is
the meaning of the LISTtitle).

This function makes sense only in a full installation of AmuseWiki, so
if the files are not in the right path, the indexing is skipped.

=cut

sub muse_file_info {
    my ($file, $root) = @_;
    die "$file not found!" unless -f $file;

    my $details = muse_parse_file_path($file, $root);
    return unless $details;

    if ($details->{f_suffix} ne '.muse') {
        $details->{uri} = $details->{f_name} . $details->{f_suffix};
        return $details;
    }

    $details->{uri} = $details->{f_name};

    my $header = muse_header_object($details->{f_full_path_name});

    $details->{lang} = $header->language;
    $details->{slides} = $header->wants_slides;

    my %parsed_header = %{ $header->header };
    foreach my $directive (keys %parsed_header) {
        unless (exists $details->{$directive}) {
            $details->{$directive} = muse_format_line(html => $parsed_header{$directive});
        }
    }


    unless (exists $details->{title} and
            length($details->{title}) and
            $details->{title} =~ m/\S/) {
        warn "Setting deletion on $file, no title found\n";
        $details->{title} = $details->{listtitle} ||= $details->{uri};
        $details->{deleted} ||= "Missing title";
    }

    my @cats;
    if (exists $details->{authors} or
        exists $details->{sortauthors}) {
        if (my @authors = $header->authors_as_html_list) {
            push @cats, map { _parse_topic_or_author(author => $_) }
              $header->authors_as_html_list;
        }
    }

    # use author as default if there is no #authors. Please note that
    # #(sort)authors could be empty or with a - in it. In this case
    # we fall into the case above and don't resort to Author. Tests
    # are in archive.t

    elsif ($details->{author}) {
        push @cats, _parse_topic_or_author(author => $details->{author});
    }
    push @cats, map { _parse_topic_or_author(topic  => $_) } $header->topics_as_html_list;
    @cats = grep { $_ } @cats;
    if (@cats) {
        $details->{parsed_categories} = \@cats;
    }
    delete $details->{$_} for qw/sortauthors sorttopics cat authors topics/;

    # handle the pubdate field

    if (my $timestring = delete $details->{pubdate}) {
        if (my $epoch = str2time($timestring, 'UTC')) {
            $details->{pubdate} = DateTime->from_epoch(epoch => $epoch);
        }
    }
    # check if we have something
    unless ($details->{pubdate}) {
        $details->{pubdate} = $details->{f_timestamp}->clone;
    }

    my $title_order_by = delete $details->{listtitle};
    if (defined $title_order_by and length($title_order_by)) {
        $details->{list_title} = $title_order_by;
    }
    else {
        $title_order_by = $details->{title};
        if (defined($title_order_by) and $title_order_by =~ m/\w/) {
            $title_order_by =~ s/^[\W]+//;
            $details->{list_title} = $title_order_by;
        }
    }

    # when headers line are removed, we don't get a proper update
    # unless we pass them to update_or_create (because the removed
    # directive is not listed).

    # title and topics are already handled
    foreach my $mandatory (qw/subtitle lang date notes 
                              author
                              teaser
                              source uid attach/) {
        unless (exists $details->{$mandatory} and
                defined $details->{$mandatory}) {
            $details->{$mandatory} = '';
        }
    }
    return $details;
}

sub muse_header_object {
    my $file = shift;
    Text::Amuse::Compile::MuseHeader
        ->new(muse_fast_scan_header($file));
}


=head2 muse_parse_file_path($file, $root, $skip_path_checking)

Given a file $file, return an hashref with the following keys:

=over 4

=item f_path

The directory

=item f_name

The basename

=item f_archive_rel_path

The archive path (e.g. a/ab)

=item f_timestamp

The file timestamp

=item f_full_path_name

The full absolute path to the file

=item f_suffix

The file extension

=item _class_

The return value of C<muse_filepath_is_valid>. You want to delete this
before you dump the item in the database, because it hints you to
which table it belongs.

=back

The second, mandatory, argument is the root of the repo. This is not
used if the third argument is provided, but could be in the future.

If the third optional argument is provided, the archive relative path
is not checked for sanity, so the file could reside anywhere. So,
without the second argument with a true value C</etc/password.muse>
would have been ignored, and C</tmp/my.muse> too. The same doesn't
happen with the switch on and the file stats are collected
nevertheless. B<This argument requires that you pass the root as the
directory of the target>. So: C</etc/password.muse> will be considered
valid only if root is C</etc>.

=cut

sub _my_suffixes {
    return qr{\.(muse|png|jpe?g|pdf)};
}


sub muse_parse_file_path {
    my ($file, $root, $skip_path_checking) = @_;
    unless ($file && $root) {
        die "Missing file ($file) and root ($root)!";
    }
    unless (File::Spec->file_name_is_absolute($file)) {
        $file = File::Spec->rel2abs($file);
    }

    unless (File::Spec->file_name_is_absolute($root)) {
        $root = File::Spec->rel2abs($root);
    }
    return unless -f $file;
    return unless -d $root;

    my $rel_file = File::Spec->abs2rel($file, $root);
    # warn "Rel path is $rel_file";

    my ($name, $path, $suffix)          = fileparse($file, _my_suffixes());
    my ($relname, $relpath, $relsuffix) = fileparse($rel_file, _my_suffixes());


    unless ($suffix) {
        # warn "$file is not a recognized file!";
        return;
    }

    if ($name ne $relname or
        $suffix ne $relsuffix) {
        die "Something fishy is going on, $name doesn't match $relname";
    }

    unless (muse_filename_is_valid($name)) {
        log_debug { "$file has not a sane name!" };
        return;
    }

    my $epoch_timestamp = (stat($file))[9];

    my %out = (
               f_path => $path,
               f_name => $name,
               f_archive_rel_path => '', # invalid by default
               f_timestamp => DateTime->from_epoch(epoch => $epoch_timestamp),
               f_timestamp_epoch => $epoch_timestamp,
               f_full_path_name  => $file,
               f_suffix => $suffix,
              );
    # warn "Parsing $relpath";
    my @dirs = grep { $_ ne '' and $_ ne '.' } File::Spec->splitdir($relpath);

    # skip path checking requires no deep path, just '.'
    if ($skip_path_checking) {
        if (!@dirs) {
            return \%out;
        }
    }
    elsif (my $class = muse_filepath_is_valid($rel_file)) {
        $out{f_archive_rel_path} = File::Spec->catdir(@dirs);
        $out{f_class} = $class;
        return \%out;
    }
    return;
}


sub _parse_muse_file {
    my ($file, $root) = @_;
    my $fileinfo = muse_parse_file_path($file, $root);
    return unless $fileinfo;
    # remove the suffix key
    if ($fileinfo->{f_suffix} ne '.muse') {
        return $fileinfo;
    }

    # scan the directives;
    my $directives = muse_fast_scan_header($fileinfo->{f_full_path_name},
                                           'html');
    unless ($directives && %$directives) {
        # title is mandatory?
        warn "$file couldn't be parsed by muse_fast_scan_header\n";
        return;
    }
    my %lowered;
    # we don't get clashes with the parsing of the muse file because
    # directives have not underscors in them

    my %out = (
               %$fileinfo,
               %lowered,
              );

    return \%out;
}


=head2 transliteration_table

Returns an hashref with the transliteration table.

=cut

sub transliteration_table  {

    my %translitterationtable =
  (
   # cyrillyc
   'а' => 'a',  'А' => 'a',    'р' => 'r',  'Р' => 'r',   
   'б' => 'b',  'Б' => 'b',    'с' => 's',  'С' => 's',   
   'в' => 'v',  'В' => 'v',    'т' => 't',  'Т' => 't',   
   'г' => 'g',  'Г' => 'g',    'у' => 'u',  'У' => 'u',   
   'д' => 'd',  'Д' => 'd',    'ф' => 'f',  'Ф' => 'f',   
   'е' => 'e',  'Е' => 'e',    'х' => 'h',  'Х' => 'h',   
   'ё' => 'e',  'Ё' => 'e',    'ц' => 'c',  'Ц' => 'c',   
   'ж' => 'j',  'Ж' => 'j',    'ч' => 'ch', 'Ч' => 'ch',  
   'з' => 'z',  'З' => 'z',    'ш' => 'sh', 'Ш' => 'sh',  
   'и' => 'i',  'И' => 'i',    'щ' => 'sch','Щ' => 'sch', 
   'й' => 'j',  'Й' => 'j',    'ь' => '',  'Ь' => '',   
   'к' => 'k',  'К' => 'k',    'ы' => 'y',  'Ы' => 'y',   
   'л' => 'l',  'Л' => 'l',    'ъ' => '',  'Ъ' => '',   
   'м' => 'm',  'М' => 'm',    'э' => 'e',  'Э' => 'e',   
   'н' => 'n',  'Н' => 'n',    'ю' => 'yu', 'Ю' => 'yu',  
   'о' => 'o',  'О' => 'o',    'я' => 'ya', 'Я' => 'ya',  
   'п' => 'p',  'П' => 'p', 

   # macedonian cyrl
   'ѓ' => 'dj',  'Ѓ' => 'dj',
   'ѕ' => 'dz',  'Ѕ' => 'dz',
   'ѝ' => 'i',   'Ѝ' => 'i',
   'ј' => 'j',   'Ј' => 'j',
   'љ' => 'lj',  'Љ' => 'lj',
   'њ' => 'nj',  'Њ' => 'nj',
   'ќ' => 'kj',  'Ќ' => 'kj',
   'џ' => 'dzh', 'Џ' => 'dzh',
   'Ѐ' => 'e',   'ѐ' => 'e',
   # the latin
   'á' => 'a',  'í' => 'i',  'ù' => 'u',  'æ' => 'ae',
   'Á' => 'a',  'ì' => 'i',  'ü' => 'u',  'Æ' => 'ae',
   'à' => 'a',  'Í' => 'i',  'ú' => 'u',  'ã' => 'a',
   'À' => 'a',  'Ì' => 'i',  'ū' => 'u',  'Ã' => 'a',
   'È' => 'e',  'ò' => 'o',  'Ū' => 'u',
   'É' => 'e',  'ó' => 'o',  'Ù' => 'u',
   'Ë' => 'e',  'ō' => 'o',  'Ü' => 'u',
   'ë' => 'e',  'Ō' => 'o',  'Ú' => 'u',
   'é' => 'e',  'Ò' => 'o',  'ç' => 'c',
   'è' => 'e',  'Ó' => 'o',  'Ç' => 'c', 
   # spanish
   'ñ' => 'n',   'Ñ' => 'n',
   # finnish
   'ä' => 'a', 'Ä' => 'a',
   'Å' => 'a', 'å' => 'a',
   'ö' => 'o', 'Ö' => 'o',
   # german
   'ß' => 'ss',
   # other northern
   'ø' => 'o',  'õ' => 'o', 
   'Ø' => 'o',  'Õ' => 'o', 
   # croatian/serbian
    'č' => 'c' , 'Č' => 'c',
    'ć' => 'c' , 'Ć' => 'c',
    'ž' => 'z' , 'Ž' => 'z',
    'š' => 's' , 'Š' => 's',
    'đ' => 'dj', 'Đ' => 'dj',
    'â' => 'a' , 'Â' => 'a',
    'ê' => 'e' , 'Ê' => 'e',
    'î' => 'i' , 'Î' => 'i',
    'ô' => 'o' , 'Ô' => 'o',
    'û' => 'u' , 'Û' => 'u',
    'ā' => 'a' , 'Ā' => 'a',

   #The only Polish letters which are different are: ą ę ć ń ś ż ź ó and
   # ł.
   # polish, from http://en.wikipedia.org/wiki/Polish_alphabet
   'ą' => 'a',  'Ą' => 'a',
   'Ę' => 'e', 	'ę' => 'e',
   'Ł' => 'l',  'ł' => 'l',
   'Ń' => 'n', 	'ń' => 'n',
   'Ś' => 's',  'ś' => 's',
   'Ź' => 'z',  'ź' => 'z',
   'Ż' => 'z',  'ż' => 'z',

   # ascii
   'A' => 'a',  'a' => 'a',   '0' => '0',   
   'B' => 'b',  'b' => 'b',   '1' => '1',   
   'C' => 'c',  'c' => 'c',   '2' => '2',   
   'D' => 'd',  'd' => 'd',   '3' => '3',   
   'E' => 'e',  'e' => 'e',   '4' => '4',   
   'F' => 'f',  'f' => 'f',   '5' => '5',   
   'G' => 'g',  'g' => 'g',   '6' => '6',   
   'H' => 'h',  'h' => 'h',   '7' => '7',   
   'I' => 'i',  'i' => 'i',   '8' => '8',   
   'J' => 'j',  'j' => 'j',   '9' => '9',   
   'K' => 'k',  'k' => 'k',   
   'L' => 'l',  'l' => 'l',   
   'M' => 'm',  'm' => 'm',   
   'N' => 'n',  'n' => 'n',   
   'O' => 'o',  'o' => 'o',   
   'P' => 'p',  'p' => 'p',   
   'Q' => 'q',  'q' => 'q',   
   'R' => 'r',  'r' => 'r',   
   'S' => 's',  's' => 's',   
   'T' => 't',  't' => 't',   
   'U' => 'u',  'u' => 'u',   
   'V' => 'v',  'v' => 'v',   
   'W' => 'w',  'w' => 'w',   
   'X' => 'x',  'x' => 'x',   
   'Y' => 'y',  'y' => 'y',   
   'Z' => 'z',  'z' => 'z',   
  );
  return \%translitterationtable;
}

=head2 muse_naming_algo($string)

Algorithm to convert an url to its canonical form, which is used as
filename. It takes a string as argument and returns it converted.

URLs can be anything which is not separated by a dot or by a
slash. The maximum length is hardcoded to 95 (as files with more than
103 characters get truncated in a CD-ROM with jolet extension. Your
url can be as long as you want, but only the first 95 characters are
used to identify it. All the rest means nothing to us. If you are
running out of names, think about adding a numeric prefix or suffix.

Non-ascii characters are first translitterated. Everything
is then lower-cased. Spaces and underscores are replaced by
dashes. Trailing and leading dashes are removed and multiple dashes
are squeezed together.

The first two characters **must** be alphanumerical. If it's not so,
the name is stripped. of the first portion until the two character
are found.

=cut


# 2000 requests => 1.258 seconds
# new algo => 0.451 seconds

sub muse_naming_algo {
    my $dirtyline = shift;
    unless ((defined $dirtyline) and ($dirtyline ne "")) {
        return "";
    }
    my $fallback = $dirtyline;
    my @chars = split //, $dirtyline;
    my @cleaned;
    while (@chars) {
        last if $#cleaned > 93; # 93 is the index, so this means we have 94 + 1 = 95
        my $char = shift @chars;
        my $trslit = transliteration_table();
        if (exists $trslit->{$char}) {
            my $good = $trslit->{$char};
            # this check if we want to push empty strings --> no dashes
            if ($good ne "") {
                push @cleaned, $good;
            }
        }
        # over the second character we put dashes to replace dirty
        # characters. But only if we have already 2 of them in the stash
        else {
            if ((@cleaned) and
                ($cleaned[$#cleaned] ne "-")) {
                push @cleaned, "-";
            }
        }
    }
    return '' unless @cleaned;
    # while looping, we counted the tokens, not the chars, so we have
    # to do it again
    @cleaned = map { split // } @cleaned;
    splice @cleaned, 95;
    # remove the trailing -
    while ($cleaned[$#cleaned] eq "-") {
        pop @cleaned;
    }
    my $clean = join ("", @cleaned);
    if ((length $clean) > 2) {
        return $clean;
    } else {
        return md5_hex(encode("UTF-8", $fallback))
    }
}

# 2000 requests for a long path with no hyphens => 0.2 seconds. 0.16 for a short one

=head2 muse_get_full_path($filename);

Given the filename $filename, return an arrayref with the three
elements composing the path to the file local to the archive, taking
the first character and the next one after the first hyphen, or the
last one.

E.g. emma-goldman-living-my-life would return 

  [ 'e', 'eg', 'emma-goldman-living-my-life' ]

Or undef if the filename is dangerous.

=cut


sub muse_get_full_path {
  my $filename = shift;
  # path required, so don't be so sure about names.
  return undef unless muse_filename_is_valid($filename);
  my @chars = split //, $filename;
  my @path;
  # given the above regexp, the first character is guaranteed to be a
  # letter or a number

  my %permitted_chars = (
                         'a' => '1',   '0' => '1',   
                         'b' => '1',   '1' => '1',   
                         'c' => '1',   '2' => '1',   
                         'd' => '1',   '3' => '1',   
                         'e' => '1',   '4' => '1',   
                         'f' => '1',   '5' => '1',   
                         'g' => '1',   '6' => '1',   
                         'h' => '1',   '7' => '1',   
                         'i' => '1',   '8' => '1',   
                         'j' => '1',   '9' => '1',   
                         'k' => '1',   		    
                         'l' => '1',   		    
                         'm' => '1',   		    
                         'n' => '1',   		    
                         'o' => '1',   		    
                         'p' => '1',   		    
                         'q' => '1',   		    
                         'r' => '1',   		    
                         's' => '1',   		    
                         't' => '1',   		    
                         'u' => '1',   		    
                         'v' => '1',   		    
                         'w' => '1',   		    
                         'x' => '1',   		    
                         'y' => '1',   		    
                         'z' => '1',
                        );

  die "we got hacked" unless $permitted_chars{$chars[0]};
  push @path, shift @chars; # and remove the first
  
  # then we look for the first hyphen.
  my $hyphen;
  foreach my $current (@chars) {
    if ($current eq "-") {
      $hyphen++;
      next;
    }
    next unless $hyphen;
    if ($permitted_chars{$current}) {
      push @path, $path[0] . $current;
      last;
    }
  }
  # ok, but what if we are still without a path because the page don't
  # have a hyphen?
  if ($#path == 1) {
    push @path, $filename;
    return \@path;
  }
  # simply we pop.
  while (@chars) {
    my $char = pop @chars;
    if ($permitted_chars{$char}) {
      push @path, $path[0] . $char;
      last;
    }
  }
  push @path, $filename;
  die "bad filename" if $#path < 2;
  return \@path;
}

sub _parse_topic_or_author {
    # use the MuseHeader class here instead with new Text::Amuse::Compile
    my ($type, $string) = @_;
    return unless $type && $string;
    # given that we get the HTML, first we strip the tags.
    $string =~ s/<.*?>//g;
    unless ($string =~ /\w/) {
        log_warn { "It looks like we stripped too much from $string" };
        return;
    }
    # then we decode the entities
    $string = decode_entities($string);
    log_debug { "Parsing $string" };
    my $uri = muse_naming_algo($string);
    return {
            name => encode_entities($string, q{<>&"'}),
            uri => $uri,
            type => $type,
           };
}

=head2 muse_filename_valid($uri)

Return true (the uri itself) if the passed uri is valid. Valid names
are lowercase and digits, with optionals hyphens inside the name, and
with a maximum length of 95 characters.

Consecutive dashes are not checked, but at least guarantees the
filename is safe.


=cut

sub muse_filename_is_valid {
    my $file = shift;
    return unless defined($file);
    if ($file =~ m/^[a-z0-9][a-z0-9\-]+[a-z0-9]$/s and length($file) <= 95) {
        return $file;
    }
    else {
        return;
    }
}

=head2 filepath_is_valid($repo_relative_path_to_file)

Return true if, and only if, these conditions are met:

=over 4

=item * The basename is valid, using C<muse_filename_is_valid>

=item * The relative path is permitted

This usually means, but with some exceptions, that it is 2 levels
deep, and looking at the basename there is a match, using the
algorithm of C<muse_get_full_path>.

=back

The return values depends on the path of the file:

=over 4

=item text

Regular title file

=item image

Regular attachment

=item special

A special page

=item upload_pdf

An uploaded pdf file

=item special_image

An attachment to the special page

=back

=cut

sub muse_filepath_is_valid {
    my $relpath = shift;
    return unless $relpath;
    log_debug { "Scanning $relpath" };
    my ($name, $path, $suffix) = fileparse($relpath, _my_suffixes());
    log_debug { "$name, $path, $suffix" };
    return unless $suffix && $path;

    my @dirs = File::Spec->splitdir($path);
    return unless @dirs;
    # remove trailing separator, if any
    if ($dirs[$#dirs] eq '') {
        pop @dirs;
    }
    return unless @dirs;
    Dlog_debug { "Dirs are $_" } \@dirs;
    return unless muse_filename_is_valid($name);
    Dlog_debug { "$name is valid" };
    # handle the pdf, which are indexed only if in the 'uploads' directory
    if (@dirs == 1) {
        my $dir = shift @dirs;

        if ($dir eq 'uploads' and $suffix eq '.pdf') {
            return 'upload_pdf';
        }
        elsif ($dir eq 'specials') {
            if ($suffix =~ m/^\.(jpe?g|png)$/s) {
                return 'special_image';
            }
            elsif ($suffix eq '.muse') {
                return 'special';
            }
        }
        # warn "$relpath not in the right dir!\n";
        return;
    }
    # then process the regular files.
    if (@dirs != 2) {
        # warn "$relpath not two levels down\n";
        return;
    }

    # check the suffixes
    unless ($suffix =~ m/^\.(muse|jpe?g|png)$/s) {
        # warn "$relpath has a suffix I don't recognize\n";
        return;
    }

    my $ret_value;
    if ($suffix eq '.muse') {
        $ret_value = 'text';
    }
    else {
        $ret_value = 'image';
    }

    # file with no hyphens, pick the first and the last
    if ($name =~ m/^([0-9a-z])[0-9a-z]+([0-9a-z])$/s) {
        if ($dirs[0] eq $1 and $dirs[1] eq "$1$2") {
            return $ret_value;
        }
        else {
            #  warn "$relpath in the wrong path!\n";
        }
    }
    elsif ($name =~ m/\A
                      ([0-9a-z]) # first letter
                      [0-9a-z]* # optional letters of first word
                      - # hyphen
                      ([0-9a-z]) # first letter of second word
                      [0-9a-z]* # optional letters of second word
                      ([0-9a-z-][0-9a-z]+)* # optional other words
                      \z/sx) {
        if ($dirs[0] eq $1 and $dirs[1] eq "$1$2") {
            return $ret_value;
        }
    }
    # catch all and return false
    log_debug { "Checking of $relpath failed" };
    return;
}

sub muse_attachment_basename_for {
    my $uri = shift;
    die "Missing muse uri!" unless $uri;
    my $pieces = muse_get_full_path($uri);
    unless ($pieces && @$pieces && @$pieces == 3) {
        die "Couldn't parse the filename... this is a bug";
    }
    # create a new filename
    my $full = join('-', @$pieces);
    my @elements = ($pieces->[0]);
    if ($pieces->[1] =~ m/^[0-9a-z]([0-9a-z])$/) {
        push @elements, $1;
    }
    else {
        die "Wrong piece, this is a bug!";
    }
    push @elements, $pieces->[2];
    my $base = muse_naming_algo(substr(join('-', @elements), 0, 50));
    return $base;
}

sub clean_username {
    my ($username) = @_;
    if ($username) {
        if ($username =~ m/\A([a-z0-9]{1,20}(\.[a-z0-9]{1,20})?)\z/) {
            return $1;
        }
        elsif ($username =~ m/\w/) {
            my $clean = lc(unidecode($username));
            $clean =~ s/[^a-z0-9]//g;
            if ($clean =~ m/([a-z0-9]{1,20})/) {
                return $1;
            }
        }
    }
    return 'anonymous';
}

sub cover_filename_is_valid {
    my ($name) = @_;
    return '' unless $name;
    if ($name =~ m/\A(.*)(\.(png|jpe?g))\z/) {
        my $base = $1;
        my $ext = $2;
        if (my $cleaned = muse_filename_is_valid($base)) {
            return $cleaned . $ext;
        }
    }
    return '';
}

sub clean_html {
    my ($string) = @_;
    return "" unless defined $string;
    $string =~ s/<.+?>//g;
    return decode_entities($string);
}

sub amw_meta_stripper {
    my ($string) = @_;
    my $meta_desc = clean_html($string);
    # strip the tags
    # strip quotes and <>
    $meta_desc =~ s/[<>"]//g;
    # inline
    $meta_desc =~ s/\s+/ /g;
    $meta_desc =~ s/\A\s+//g;
    $meta_desc =~ s/\s+\z//g;
    # cut at 160
    if (length($meta_desc) > 157) {
        $meta_desc = substr($meta_desc, 0, 157);
        # cut at the last space
        $meta_desc =~ s/\s+\S*\z//s;
        if ($meta_desc) {
            $meta_desc .= '...';
        }
    }
    return $meta_desc;
}

sub to_json {
    my ($data, %opts) = @_;
    my $json;
    try {
        $json = JSON::MaybeXS->new(
                                   ascii => (defined $opts{ascii} ? $opts{ascii} : 1),
                                   pretty => (defined $opts{pretty} ? $opts{pretty} : 0),
                                   canonical => (defined $opts{canonical} ? $opts{canonical} : 0)
                                  )->encode($data);
    } catch {
        my $error = $_;
        Dlog_error { "$error: Failed to encode into json $_" } $data;
    };
    return $json;
}

sub from_json {
    my ($json) = @_;
    my $data;
    try {
        $data = JSON::MaybeXS->new->decode($json);
    } catch {
        my $error = $_;
        log_error { "$error: Failed to decode json $json" };
    };
    return $data;
}

sub image_dimensions {
    my ($file) = @_;
    my ($w, $h);
    if ($file and -f $file and $file =~ m/\.(jpe?g|png)\z/) {
        try {
            require Imager;
            Imager->set_file_limits(reset => 1);
            my $img = Imager->new(file => "$file") or die Imager->errstr;
            $w = $img->getwidth;
            $h = $img->getheight;
            log_debug { "$file: W:$w H:$h" };
        } catch {
            my $error = $_;
            log_error { "Failed to compute image dimensions for $file: $error" };
        };
    }
    return ($w, $h);
}

sub split_pdf {
    my ($pdf, $directory) = @_;
    die "Missing $pdf" unless $pdf;
    die "Missing directory" unless $directory;
    $directory = path($directory);
    require PDF::API2;
    my @images;
    try {
        # first, we read the PDF and split it by page. This way we
        # also convert the PDF to a lower version. This makes it more
        # difficult (probably not impossible) for exploits to reach
        # the gs executable.
        my $pdf = PDF::API2->open("$pdf");
        my $count = $pdf->pages;
        my $p = 0;
        while ($p < $count) {
            $p++;
            my $outpdf = PDF::API2->new;
            $outpdf->import_page($pdf, $p);
            $outpdf->saveas(path($directory, sprintf('page-%04d.pdf', $p))->stringify);
        }
        $pdf->end;
        foreach my $page (sort $directory->children(qr/\.pdf/)) {
            if (my $image = convert_pdf_to_png($page, $directory->child($page->basename(qr/\.pdf/) . '.png'))) {
                push @images, $image;
            }
        }
    } catch {
        my $err = $_;
        log_error { "Failure to split the pdf $pdf into $directory $err" };
    };
    if (@images) {
        return @images;
    }
    else {
        return;
    }
}

sub convert_pdf_to_png {
    my ($input, $output) = @_;
    die "Bad usage" unless $input && $output;
    die "$input is not a file" unless -f $input;
    my @exec = (qw/gs -q -dSAFER -sDEVICE=png16m -dNOPAUSE -dBATCH
                   -dUseCropBox -dTextAlphaBits=4 -dGraphicsAlphaBits=4
                   -dMaxBitmap=50000000 -r300
                  /);
    push @exec, "-sOutputFile=$output", "$input";
    Dlog_debug { "Executing $_" } \@exec;
    if (system(@exec) == 0) {
        return $output;
    }
    else {
        Dlog_error { "Execution of $_ failed" } \@exec;
    }
}

sub create_thumbnail {
    my ($input, $output, $width) = @_;
    return unless $input && $output && $width;
    my ($w, $h);
    try {
        ($w, $h) = _generate_thumbnail($input, $output, $width);
    } catch {
        my $err = $_;
        log_error { "Failure to create thumbnail $input => $output => $width with error $err" };
    };
    return ($w, $h);
}

sub _generate_thumbnail {
    my ($input, $output, $width) = @_;
    die unless $input && $output && $width;
    my $wd = Path::Tiny->tempdir;
    if ($input =~ m/\.pdf\z/) {
        require PDF::API2;
        my $in = PDF::API2->open("$input");
        my $out = PDF::API2->new;
        $out->import_page($in, 1);
        my $outpdf = $wd->child("firstpage.pdf");
        my $outpng = $wd->child("firstpage.png");
        $out->saveas("$outpdf");
        $in->end;
        convert_pdf_to_png("$outpdf", "$outpng");
        log_debug { "Using $outpng instead of $input" };
        $input = $outpng; # consider our PNG as the source;
    }
    require Imager;
    Imager->set_file_limits(reset => 1);
    my $img = Imager->new(file => "$input") or die Imager->errstr;
    log_debug { "Scaling $input into $output with $width" };
    my $thumb = $img->scale(xpixels => $width, qtype => 'mixing');
    $thumb->write(file => $output);
    return ($thumb->getwidth, $thumb->getheight);
}

sub strip_image {
    my ($input, $output) = @_;
    require Imager;
    Imager->set_file_limits(width => 4000,
                            height => 4000);
    my $incoming = Imager->new(file => $input) or die Imager->errstr;
    my $img = $incoming->copy;
    undef $incoming;
    log_debug { "Writing $input image into $output" };
    # tags are already stripped.
    $img->write(file => $output);
    undef $img;
    die "$output not written!" unless -f $output;
}

sub known_langs {
    return {
            ru => 'Русский',
            sr => 'Srpski',
            hr => 'Hrvatski',
            mk => 'Македонски',
            fi => 'Suomi',
            id => 'Bahasa Indonesia',
            it => 'Italiano',
            es => 'Español',
            en => 'English',
            fr => 'Français',
            nl => 'Nederlands',
            de => 'Deutsch',
            sq => 'Shqip',
            sv => 'Svenska',
            pl => 'Polski',
            pt => 'Português',
            da => 'Dansk',
            cs => 'Čeština',
            tr => 'Türkçe',
           };
}

1;
