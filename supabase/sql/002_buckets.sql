-- create storage buckets via SQL
insert into storage.buckets (id, name, public) values ('entry-images','entry-images', false) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('entry-audio','entry-audio', false) on conflict (id) do nothing;
