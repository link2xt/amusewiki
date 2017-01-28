package AmuseWikiFarm::Controller::Settings;
use Moose;
use namespace::autoclean;

use AmuseWikiFarm::Log::Contextual;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

AmuseWikiFarm::Controller::Settings - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut


=head2 index

=cut

sub settings :Chained('/site_user_required') :CaptureArgs(0) {
    my ($self, $c) = @_;
}

sub list_custom_formats :Chained('settings') :PathPart('formats') :CaptureArgs(0) {
    my ($self, $c) = @_;
    unless ($c->check_any_user_role(qw/admin root/)) {
        $c->detach('/not_permitted');
        return;
    }
}

sub formats :Chained('list_custom_formats') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    my @list;
    my $formats = $c->stash->{site}->custom_formats;
    while (my $format = $formats->next) {
        my $id =  $format->custom_formats_id;
        push @list, {
                     id => $id,
                     edit_url => $c->uri_for_action('/settings/edit_format', [ $id ]),
                     deactivate_url => $c->uri_for_action('/settings/make_format_inactive', [ $id ]),
                     activate_url   => $c->uri_for_action('/settings/make_format_active', [ $id ]),
                     name => $format->format_name,
                     description => $format->format_description,
                     active => $format->active,
                    };
    }
    # Dlog_debug { "Found these formats $_" } \@list;
    $c->stash(
              format_list => \@list,
              create_url => $c->uri_for_action('/settings/create_format'),
              page_title => $c->loc('Custom formats for [_1]', $c->stash->{site}->canonical),
             );
}

sub create_format :Chained('list_custom_formats') :PathPart('create') :Args(0) {
    my ($self, $c) = @_;
    my %params = %{ $c->request->body_parameters };
    if ($params{format_name} and length($params{format_name}) < 255) {
        my $f = $c->stash->{site}->custom_formats->create({ format_name => "$params{format_name}"});
        log_debug { "Created " . $f->format_name };
        $f->discard_changes;
        $c->response->redirect($c->uri_for_action('/settings/edit_format', [ $f->custom_formats_id ]));
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub get_format :Chained('list_custom_formats') :PathPart('edit') :CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    log_debug { "Getting format id $id" };
    if ($id =~ m/([0-9]+)/) {
        if (my $format = $c->stash->{site}->custom_formats->find($id)) {
            $c->stash(edit_custom_format => $format);
            return;
        }
    }
    $c->detach('/not_found');
}

sub edit_format :Chained('get_format') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
}

sub make_format_inactive :Chained('get_format') :PathPart('inactive') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "setting active => 0 $_" } $c->request->body_parameters;
    $c->stash->{edit_custom_format}->update({ active => 0 }) if $c->request->body_parameters->{go};
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub make_format_active :Chained('get_format') :PathPart('active') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "setting active => 1 $_" } $c->request->body_parameters;
    $c->stash->{edit_custom_format}->update({ active => 1 }) if $c->request->body_parameters->{go};
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}


=encoding utf8

=head1 AUTHOR

Marco,,,

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;