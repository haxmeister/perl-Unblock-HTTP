use strict;
use warnings;
use Test::More;

use_ok('Unblock::HTTP');
use_ok('Unblock::HTTP::Client');
use_ok('Unblock::HTTP::_ClientOperation');
use_ok('Unblock::HTTP::_AltSvc');
use_ok('Unblock::HTTP::Server');
use_ok('Unblock::HTTP::Integration');
use_ok('Unblock::HTTP::QUIC');

is($Unblock::HTTP::VERSION, '0.01', 'distribution version');
done_testing;
