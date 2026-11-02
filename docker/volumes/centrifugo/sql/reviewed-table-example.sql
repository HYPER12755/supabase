-- Example only. Review the table's privacy model before applying it.
--
-- The trigger publishes notification-only events for this table:
--   tenant:<tenant_id>:table:<table_name>
--
-- The tenant key must be a UUID column. The trigger is AFTER, so the event is
-- committed atomically with the row change and consumers only see committed events.
--
-- Notification-only payload:
--   { event, schema, table, tenant_id, occurred_at, message_id }
--
-- Full-row payloads are opt-in and bypass the table's RLS policies because the
-- trigger function runs as its owner. Only add tables whose full rows may be
-- delivered to every member of the tenant channel.

DROP TRIGGER IF EXISTS messages_centrifugo_changes ON public.messages;

CREATE TRIGGER messages_centrifugo_changes
AFTER INSERT OR UPDATE OR DELETE ON public.messages
FOR EACH ROW
EXECUTE FUNCTION centrifugo.broadcast_changes_trigger('tenant_id');

-- Optional: include full rows in the payload. Apply only after review.
--
-- INSERT INTO centrifugo.full_payload_tables (schema_name, table_name)
-- VALUES ('public', 'messages')
-- ON CONFLICT (schema_name, table_name) DO UPDATE SET enabled = true;
