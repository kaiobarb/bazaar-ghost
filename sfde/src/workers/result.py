"""Result worker: batch detections and upload to Supabase."""

import queue

from workers.context import PipelineContext


def run(ctx: PipelineContext) -> None:
    try:
        while not ctx.shutdown.is_set():
            try:
                result = ctx.result_queue.get(timeout=1)
                ctx.result_batch.append(result)

                ctx.all_detections.append(
                    {
                        "timestamp": result["timestamp"],
                        "username": result["username"],
                        "confidence": result.get("confidence", 0),
                        "rank": result.get("detected_rank"),
                        "frame_base64": result.get("frame_base64"),
                    }
                )

                if len(ctx.result_batch) >= ctx.config["supabase"]["batch_size"]:
                    ctx.supabase.upload_batch(ctx.result_batch)
                    ctx.result_batch = []

            except queue.Empty:
                continue

    except Exception as e:
        ctx.logger.error(f"Result worker failed: {e}")
    finally:
        if ctx.result_batch:
            ctx.logger.info(
                f"Flushing final batch of {len(ctx.result_batch)} detections"
            )
            ctx.supabase.upload_batch(ctx.result_batch)
            ctx.result_batch = []
