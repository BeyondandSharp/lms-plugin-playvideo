package Plugins::PlayVideo::Importer;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

=head2 preinitPlugin / initPlugin

Lyrion Music Server plugins can be loaded through an C<importmodule>
declaration in F<install.xml> (legacy scanners) as well as through the
regular plugin module.  Both entry points make sure the PlayVideo
metadata reader is registered for its content types.

=cut

sub preinitPlugin {
	return _register();
}

sub initPlugin {
	return _register();
}

sub _register {
	return 0 unless eval { require Plugins::PlayVideo::Formats; 1 };

	return eval { Plugins::PlayVideo::Formats->register() } ? 1 : 0;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Importer - format registration for the PlayVideo plugin

=head1 DESCRIPTION

Registers L<Plugins::PlayVideo::Formats> for the MP4 style files and for
all PlayVideo content types.  Referenced from F<install.xml> with
C<E<lt>importmoduleE<gt>> and/or called from the plugin initialization.

=cut
