"""Process-owned fake feed and isolated install for the native manager test."""
import json
import sys
from test_release import ReleaseTests

fixture = ReleaseTests('test_fake_latest_redirect_check_and_manager_update')
fixture.setUp()
try:
    fixture.cli()
    fixture.fixture('v1.0.1')
    with fixture.feed() as environment:
        print(json.dumps({'home': str(fixture.home),
                          'resources': str(fixture.home/'Applications/Mac Utilities.app/Contents/Resources'),
                          'feed': environment['MAC_UTILITIES_RELEASE_BASE_URL']}), flush=True)
        sys.stdin.read()  # The parent closes stdin when the native test ends.
finally:
    fixture.tearDown()
