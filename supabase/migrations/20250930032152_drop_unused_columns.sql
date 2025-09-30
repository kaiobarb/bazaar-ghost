drop view if exists "public"."visible_detections";

alter table "public"."chunks" drop column "worker_id";

alter table "public"."detections" drop column "ocr_text";

alter table "public"."detections" drop column "processing_metadata";


