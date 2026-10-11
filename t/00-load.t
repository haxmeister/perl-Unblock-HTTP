use strict;
use warnings;
use Test::More;

use_ok('Unblock::HTTP');
use_ok('Unblock::HTTP::Client');
use_ok('Unblock::HTTP::Server');
use_ok('Unblock::HTTP::Integration');

is($Unblock::HTTP::VERSION, '0.01', 'distribution version');
done_testing;
