#!/usr/bin/env python3
"""Read-only check of the protected App Review account; never send SMS or log secrets."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import asc_listing

BASE = 'https://fit.tianli.cyou'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = {'checked_at': datetime.now(timezone.utc).isoformat(), 'service': BASE,
              'credential_source': 'original protected FITCOACH_REVIEW_EMAIL/FITCOACH_REVIEW_PW',
              'scope': 'one email/password login and read-only coach API; no client UI or Store-package claim',
              'real_sms_sent': 0, 'checks': {}, 'requests': []}
    cookie = None

    def request(path, fields=None):
        # No redirects: credentials/cookie must stay on the fixed HTTPS origin.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *unused, **kwargs):
                return None
        headers = {'Accept': 'application/json', 'User-Agent': 'FitcoachReviewCheck/1.0'}
        if cookie:
            headers['Cookie'] = 'fc_coach=' + cookie
        data = None
        if fields is not None:
            data = urllib.parse.urlencode(fields).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req = urllib.request.Request(BASE + path, data=data, headers=headers)
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=30) as response:
                report['requests'].append({'path': path, 'status': response.status})
                return json.load(response)
        except urllib.error.HTTPError as exc:
            report['requests'].append({'path': path, 'status': exc.code})
            raise RuntimeError('review API returned HTTP ' + str(exc.code)) from None

    try:
        demo = asc_listing.load_product('fitcoach-ios')['store']['demo']
        assert demo['email_env'] == 'FITCOACH_REVIEW_EMAIL' and demo['pw_env'] == 'FITCOACH_REVIEW_PW'
        login = request('/api/login', {'email': asc_listing.asc._personal_env(demo['email_env']),
                                       'password': asc_listing.asc._personal_env(demo['pw_env'])})
        cookie = login.get('cookie')
        report['checks']['email_login'] = login.get('ok') is True and bool(cookie)
        if not report['checks']['email_login']:
            raise RuntimeError('review login did not return a valid session')
        ping = request('/coach/api/ping')
        report['checks']['coach_session'] = ping.get('ok') is True
        students = request('/coach/api/students')
        schedule = request('/coach/api/schedule?range=today')
        rows = students.get('rows') if isinstance(students, dict) else None
        report['checks']['students_readable'] = isinstance(rows, list)
        report['checks']['schedule_readable'] = isinstance(schedule, dict) and isinstance(schedule.get('days'), list)
        rows = rows if isinstance(rows, list) else []
        report['student_count'] = len(rows)
        report['checks']['representative_students_present'] = len(rows) > 0
        report['ok'] = all(report['checks'].values())
    except (Exception, SystemExit) as exc:
        # No bodies, values, cookies, account identifiers or traceback locals.
        report['ok'] = False
        report['error_type'] = type(exc).__name__
        if isinstance(exc, urllib.error.URLError):
            report['network_error_type'] = type(exc.reason).__name__
            report['network_errno'] = getattr(exc.reason, 'errno', None)
        if isinstance(exc, RuntimeError):
            report['error'] = str(exc)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
