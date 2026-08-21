-- Facts were indexed by value alone, so a lookup by key ("landlord") missed its
-- own fact. Re-index every fact as "key: value".
DELETE FROM chunks WHERE kind = 'fact';
INSERT INTO chunks(text, kind, ref) SELECT key || ': ' || value, 'fact', key FROM facts;
