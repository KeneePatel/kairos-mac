# Verifier suite fixtures

One file per job: a small master resume and tailored bullets for that job, each with the rules it must break (`expect`, empty for a bullet that's grounded). `VerifierSuite` runs every file through the verifier and reports each mismatch with the file, the bullet and the rule.

Success criterion S9 needs 30 jobs with 0 unsupported claims in strict mode and 0 hard-limit violations in stretch mode. T33 started the suite with 3 jobs of hand-written bullets; T34's writers and T39's evals add real writer output until there are 30.

```json
{
  "job": "What the posting is, for the report",
  "mode": "strict",
  "hiringCompany": "Northline Freight",
  "companyProducts": ["FreightOS"],
  "resume": {
    "totalYears": 5,
    "skills": [{ "name": "Go", "level": "proven" }],
    "experience": [{ "employer": "…", "title": "…", "start": "2022-03", "end": null,
                     "bullets": [{ "id": "b1", "text": "…", "metrics": [], "skills": ["Go"] }] }],
    "education": [{ "institution": "…", "credential": "BMath", "field": "Computer Science" }],
    "certifications": ["AWS Solutions Architect – Associate"]
  },
  "bullets": [{ "text": "…", "sources": ["b1"], "gap": false, "expect": [] }]
}
```

Bullet ids are short names local to the file; a source that names no bullet stands for an id the master resume doesn't have. Fixtures use fictional people and companies only.
