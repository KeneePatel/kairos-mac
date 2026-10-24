#!/usr/bin/env python3
"""Builds Kairos's board catalog: companies' public job boards with jobs in Canada or the US.

Job collection v2, J5 (docs/research/job-collection/05-company-discovery.md). It reads Common
Crawl's URL index for the job-board hosts of the nine ATSs Kairos reads, keeps each company's
slug, asks each board's public API once, and writes the boards that list jobs in Canada or the
US, with their counts, to the catalog the app bundles. The app never crawls; refresh the catalog
by running this before a release:

    python3 -I scripts/discover-boards.py [--crawls 2] [--limit N] [--out PATH]

Standard library only. Polite: at most 4 requests at a time, a pause between them, retries with
backoff, and an identifying User-Agent. Boards already in the catalog are checked again, so a
board that went away drops out. Takes 10 to 20 minutes for two crawls.
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

AGENT = "Kairos board catalog (+https://github.com/KeneePatel/kairos-mac)"
INDEX = "https://index.commoncrawl.org"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "Packages", "KairosCore", "Sources", "JobSources", "Catalog", "boards.json")

# (index query, kind, how the slug is read from a URL). Path boards take the first path segment;
# subdomain boards take the subdomain.
HOSTS = [
    ("job-boards.greenhouse.io/*", "greenhouse", "path"),
    ("boards.greenhouse.io/*", "greenhouse", "path"),
    ("jobs.lever.co/*", "lever", "path"),
    ("jobs.eu.lever.co/*", "lever-eu", "path"),
    ("jobs.ashbyhq.com/*", "ashby", "path"),
    ("apply.workable.com/*", "workable", "path"),
    ("jobs.smartrecruiters.com/*", "smartrecruiters", "path"),
    ("*.recruitee.com", "recruitee", "subdomain"),
    ("*.jobs.personio.de", "personio", "subdomain"),
    ("*.bamboohr.com", "bamboohr", "subdomain"),
    ("*.teamtailor.com", "teamtailor", "subdomain"),
]
NOT_COMPANIES = {
    "", "www", "api", "app", "apply", "embed", "j", "jobs", "job", "careers", "career-site", "help", "support",
    "status", "blog", "docs", "developers", "partners", "marketplace", "static", "assets", "cdn", "login",
    "favicon.ico", "robots.txt", "sitemap.xml", "v1", "o",
}
SLUG = re.compile(r"^[A-Za-z0-9_-]{1,100}$")

PROVINCES = r"ON|BC|QC|AB|MB|SK|NS|NB|NL|PE|YT|NT|NU"
CANADA = re.compile(
    r"\bcanada\b|\bcanadian\b|, ?(" + PROVINCES + r")\b|\b(ontario|british columbia|quebec|québec|alberta|manitoba|"
    r"saskatchewan|nova scotia|new brunswick|newfoundland|prince edward island|toronto|vancouver|montr[eé]al|"
    r"ottawa|calgary|edmonton|waterloo|kitchener|halifax|winnipeg|victoria, bc|mississauga|burnaby|markham|"
    r"quebec city|saskatoon|regina|fredericton|moncton|st\. john's|charlottetown)\b",
    re.IGNORECASE)
STATES = (r"AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|"
          r"ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC")
UNITED_STATES = re.compile(
    r"\bunited states\b|\busa\b|\bu\.s\.|\bus\b|, ?(" + STATES + r")\b|\b(new york|san francisco|seattle|austin|"
    r"boston|chicago|los angeles|denver|atlanta|miami|washington, d\.?c)\b",
    re.IGNORECASE)


def get(url, accept="application/json", timeout=30, tries=3):
    """The body of `url`, the final URL after redirects, and the status; None on failure."""
    for attempt in range(tries):
        request = urllib.request.Request(url, headers={"User-Agent": AGENT, "Accept": accept})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read(), response.geturl(), response.status
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return None
            if error.code == 429 or error.code >= 500:
                time.sleep(2 * (attempt + 1) + int(error.headers.get("Retry-After", "0") or 0))
                continue
            return None
        except Exception:
            time.sleep(2 * (attempt + 1))
    return None


def crawls(count):
    body = get(INDEX + "/collinfo.json")
    if not body:
        sys.exit("Common Crawl's index list didn't load")
    return [crawl["id"] for crawl in json.loads(body[0])[:count]]


def index_urls(crawl, query):
    """Every URL the crawl's index has for `query`, page by page."""
    encoded = urllib.parse.quote(query, safe="*/:.")
    pages = get(f"{INDEX}/{crawl}-index?url={encoded}&output=json&showNumPages=true", timeout=120, tries=4)
    if not pages:
        return []
    try:
        count = json.loads(pages[0]).get("pages", 0)
    except ValueError:
        return []
    urls = []
    for page in range(count):
        body = get(f"{INDEX}/{crawl}-index?url={encoded}&output=json&fl=url&page={page}", timeout=180, tries=5)
        if not body:
            continue
        for line in body[0].decode("utf-8", "replace").splitlines():
            try:
                urls.append(json.loads(line)["url"])
            except (ValueError, KeyError):
                pass
        time.sleep(1)
    return urls


def slug_of(url, how, suffix):
    parsed = urllib.parse.urlparse(url)
    if how == "path":
        segment = parsed.path.strip("/").split("/")[0] if parsed.path.strip("/") else ""
        return urllib.parse.unquote(segment)
    host = (parsed.hostname or "").lower()
    return host[: -len(suffix)] if host.endswith(suffix) else ""


def humanize(slug):
    return " ".join(part.capitalize() for part in re.split(r"[-_]+", slug) if part) or slug


def count(places):
    """Jobs in Canada and in the US among each job's place strings."""
    canada = sum(1 for place in places if CANADA.search(place or ""))
    states = sum(1 for place in places if not CANADA.search(place or "") and UNITED_STATES.search(place or ""))
    return canada, states


def check(kind, slug):
    """What the board's public API says: its name and where its jobs are. None if it isn't a board."""
    time.sleep(0.25)
    if kind == "greenhouse":
        jobs = get(f"https://boards-api.greenhouse.io/v1/boards/{slug}/jobs")
        if not jobs:
            return None
        listing = json.loads(jobs[0]).get("jobs", [])
        board = get(f"https://boards-api.greenhouse.io/v1/boards/{slug}")
        name = json.loads(board[0]).get("name") if board else None
        return name, [(job.get("location") or {}).get("name", "") for job in listing]
    if kind in ("lever", "lever-eu"):
        host = "api.eu.lever.co" if kind == "lever-eu" else "api.lever.co"
        body = get(f"https://{host}/v0/postings/{slug}?mode=json")
        if not body:
            return None
        postings = json.loads(body[0])
        if not isinstance(postings, list):
            return None
        return None, [" ".join(filter(None, [(p.get("categories") or {}).get("location"), p.get("country"),
                                             " ".join((p.get("categories") or {}).get("allLocations") or [])]))
                      for p in postings]
    if kind == "ashby":
        body = get(f"https://api.ashbyhq.com/posting-api/job-board/{slug}")
        if not body:
            return None
        jobs = [job for job in json.loads(body[0]).get("jobs", []) if job.get("isListed", True)]
        return None, [" ".join(filter(None, [job.get("location"), ((job.get("address") or {}).get("postalAddress") or {})
                                             .get("addressCountry")] + [s.get("location") for s in job.get("secondaryLocations") or []]))
                      for job in jobs]
    if kind == "workable":
        body = get(f"https://apply.workable.com/api/v1/widget/accounts/{slug}")
        if not body:
            return None
        board = json.loads(body[0])
        places = []
        for job in board.get("jobs", []):
            codes = [location.get("countryCode") for location in job.get("locations") or []]
            places.append(" ".join(["Canada" if code == "CA" else "United States" if code == "US" else (code or "")
                                    for code in codes] + [job.get("country") or ""]))
        return board.get("name"), places
    if kind == "smartrecruiters":
        found = {}
        name = None
        for country in ("ca", "us"):
            body = get(f"https://api.smartrecruiters.com/v1/companies/{slug}/postings?limit=1&country={country}")
            if not body:
                return None
            page = json.loads(body[0])
            found[country] = page.get("totalFound", 0)
            for item in page.get("content", []):
                name = name or (item.get("company") or {}).get("name")
        return name, ["Canada"] * found["ca"] + ["United States"] * found["us"]
    if kind == "recruitee":
        body = get(f"https://{slug}.recruitee.com/api/offers/")
        if not body or urllib.parse.urlparse(body[1]).hostname != f"{slug}.recruitee.com":
            return None
        offers = json.loads(body[0]).get("offers", [])
        name = offers[0].get("company_name") if offers else None
        return name, [" ".join(filter(None, [offer.get("location"), offer.get("country")])) for offer in offers]
    if kind == "personio":
        body = get(f"https://{slug}.jobs.personio.de/xml?language=en", accept="application/xml")
        if not body or urllib.parse.urlparse(body[1]).hostname != f"{slug}.jobs.personio.de":
            return None
        try:
            root = ElementTree.fromstring(body[0])
        except ElementTree.ParseError:
            return None
        positions = root.findall("position")
        name = next((p.findtext("subcompany") for p in positions if p.findtext("subcompany")), None)
        return name, [" ".join(filter(None, [p.findtext("office")] + [o.text for o in p.findall("additionalOffices/office")]))
                      for p in positions]
    if kind == "bamboohr":
        body = get(f"https://{slug}.bamboohr.com/careers/list")
        if not body or urllib.parse.urlparse(body[1]).hostname != f"{slug}.bamboohr.com":
            return None
        try:
            result = json.loads(body[0]).get("result", [])
        except ValueError:
            return None
        return None, [" ".join(filter(None, [(item.get("atsLocation") or {}).get("country"),
                                             (item.get("atsLocation") or {}).get("city")])) for item in result]
    if kind == "teamtailor":
        body = get(f"https://{slug}.teamtailor.com/jobs.rss", accept="application/rss+xml")
        if not body:
            return None
        try:
            channel = ElementTree.fromstring(body[0]).find("channel")
        except ElementTree.ParseError:
            return None
        if channel is None:
            return None
        namespace = {"tt": "https://teamtailor.com/locations"}
        places = [" ".join(filter(None, [location.findtext("tt:city", namespaces=namespace),
                                         location.findtext("tt:country", namespaces=namespace)]))
                  for item in channel.findall("item") for location in item.findall("tt:locations/tt:location", namespace)]
        return channel.findtext("title"), places
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--crawls", type=int, default=2, help="how many of the latest crawls to read")
    parser.add_argument("--limit", type=int, default=0, help="check at most this many boards (testing)")
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    candidates = set()
    for crawl in crawls(args.crawls):
        for query, kind, how in HOSTS:
            suffix = query[1:] if how == "subdomain" else ""
            urls = index_urls(crawl, query)
            slugs = {slug_of(url, how, suffix) for url in urls}
            slugs = {slug for slug in slugs if SLUG.match(slug) and slug.lower() not in NOT_COMPANIES}
            # Smartrecruiters ids are case-sensitive; every other slug is lowercase on its board.
            slugs = slugs if kind == "smartrecruiters" else {slug.lower() for slug in slugs}
            candidates |= {(kind, slug) for slug in slugs}
            print(f"{crawl} {query}: {len(urls)} URLs, {len(slugs)} boards", file=sys.stderr)
    if os.path.exists(args.out):
        with open(args.out) as existing:
            for board in json.load(existing).get("boards", []):
                kind = "lever-eu" if board["kind"] == "lever" and board.get("region") == "eu" else board["kind"]
                candidates.add((kind, board["slug"]))
    candidates = sorted(candidates)
    if args.limit:
        candidates = candidates[: args.limit]
    print(f"checking {len(candidates)} boards", file=sys.stderr)

    boards = []
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        futures = {pool.submit(check, kind, slug): (kind, slug) for kind, slug in candidates}
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            kind, slug = futures[future]
            try:
                answer = future.result()
            except Exception:
                answer = None
            if done % 250 == 0:
                print(f"  {done} of {len(candidates)} checked, {len(boards)} kept", file=sys.stderr)
            if not answer:
                continue
            name, places = answer
            canada, states = count(places)
            if canada == 0 and states == 0:
                continue
            entry = {"kind": "lever" if kind == "lever-eu" else kind, "slug": slug,
                     "name": (name or humanize(slug)).strip(), "ca": canada, "us": states, "jobs": len(places)}
            if kind == "lever-eu":
                entry["region"] = "eu"
            boards.append(entry)

    boards.sort(key=lambda board: (board["kind"], board["slug"].lower()))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as out:
        json.dump({"checked": datetime.date.today().isoformat(), "boards": boards}, out, indent=0, ensure_ascii=False)
        out.write("\n")
    print(f"kept {len(boards)} boards: {sum(1 for b in boards if b['ca'])} with Canadian jobs, "
          f"{sum(1 for b in boards if b['us'])} with US jobs → {os.path.relpath(args.out)}", file=sys.stderr)


if __name__ == "__main__":
    main()
