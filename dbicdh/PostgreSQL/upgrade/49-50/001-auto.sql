-- Convert schema '/home/melmoth/amw/AmuseWikiFarm/dbicdh/_source/deploy/49/001-auto.yml' to '/home/melmoth/amw/AmuseWikiFarm/dbicdh/_source/deploy/50/001-auto.yml':;

;
BEGIN;

;
ALTER TABLE custom_formats ADD COLUMN bb_areaset_height integer DEFAULT 0 NOT NULL;

;
ALTER TABLE custom_formats ADD COLUMN bb_areaset_width integer DEFAULT 0 NOT NULL;

;
ALTER TABLE custom_formats ADD COLUMN bb_fussy_last_word smallint DEFAULT 0;

;
ALTER TABLE custom_formats ADD COLUMN bb_tex_emergencystretch integer DEFAULT 30 NOT NULL;

;
ALTER TABLE custom_formats ADD COLUMN bb_tex_tolerance integer DEFAULT 200 NOT NULL;

;
ALTER TABLE custom_formats ADD COLUMN bb_ignore_cover smallint DEFAULT 0;

;

COMMIT;

