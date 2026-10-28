-- 012: your roles (job collection v2, J3). The owner chose all four kinds of work on 2026-10-23;
-- saved search settings without roles get them. A fresh install has no setting yet and starts with
-- none, so nothing is left out until you choose.

UPDATE setting SET value = json_set(value, '$.roles', json('["software","devops","data","qa"]'))
WHERE key = 'screening' AND json_type(value, '$.roles') IS NULL;
