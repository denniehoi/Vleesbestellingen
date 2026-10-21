-- Vleesbestellingen: database-opzet voor Supabase.
-- Plak dit hele bestand in Supabase > SQL Editor > New query en klik op Run.
-- Je kunt het veilig vaker draaien: bestaande gegevens blijven staan.
--
-- Opbouw: alle gegevens staan in één tabel `docs` (collectie + id + JSON).
-- Niemand kan de tabellen direct lezen of schrijven. Alles loopt via de
-- functies hieronder, en die controleren eerst de pincode.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.docs (
  collection text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);

-- '__beheer__' voor de beheerderscode, anders het id van een keuken
create table if not exists public.pincodes (
  wie      text primary key,
  pin_hash text not null
);

create table if not exists public.inlogpogingen (
  id bigserial primary key,
  op timestamptz not null default now()
);

alter table public.docs          enable row level security;
alter table public.pincodes      enable row level security;
alter table public.inlogpogingen enable row level security;
revoke all on public.docs, public.pincodes, public.inlogpogingen from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Interne hulpfunctie: wie hoort bij deze pincode? (null = niemand)
-- Na 30 foute pogingen binnen 15 minuten wordt inloggen tijdelijk geblokkeerd.
create or replace function public._wie(p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r record; fouten int;
begin
  delete from inlogpogingen where op < now() - interval '1 day';
  select count(*) into fouten from inlogpogingen where op > now() - interval '15 minutes';
  if fouten >= 30 then
    raise exception 'Te veel foute pogingen. Probeer het over een kwartier opnieuw.';
  end if;
  if p_pin is null or length(p_pin) < 4 then
    insert into inlogpogingen default values; return null;
  end if;
  for r in select wie, pin_hash from pincodes loop
    if crypt(p_pin, r.pin_hash) = r.pin_hash then return r.wie; end if;
  end loop;
  insert into inlogpogingen default values;
  return null;
end $$;
revoke execute on function public._wie(text) from public, anon, authenticated;

create or replace function public._rij(p_collection text, p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select data || jsonb_build_object('id', id) from docs where collection = p_collection and id = p_id
$$;
revoke execute on function public._rij(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Openbaar: is er al een beheerderscode ingesteld?
create or replace function public.status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('ingericht', exists(select 1 from pincodes where wie = '__beheer__'))
$$;

-- Eerste keer: beheerderscode kiezen (werkt alleen zolang er nog geen is)
create or replace function public.beheer_eerste_keer(p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists(select 1 from pincodes where wie = '__beheer__') then
    return jsonb_build_object('fout', 'Er is al een beheerderscode ingesteld.');
  end if;
  if p_pin !~ '^[0-9]{6,12}$' then
    return jsonb_build_object('fout', 'De beheerderscode moet uit 6 tot 12 cijfers bestaan.');
  end if;
  insert into pincodes(wie, pin_hash) values ('__beheer__', crypt(p_pin, gen_salt('bf')));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.inloggen(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text;
begin
  w := _wie(p_pin);
  if w is null then return jsonb_build_object('fout', 'Deze code kennen we niet.'); end if;
  if w = '__beheer__' then return jsonb_build_object('rol', 'beheer'); end if;
  return jsonb_build_object('rol', 'keuken', 'keuken', _rij('keukens', w));
end $$;

-- ---------------------------------------------------------------------------
-- Keuken: eigen bestelling ophalen en opslaan
create or replace function public.keuken_ophalen(p_pin text, p_week text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text; wk jsonb; bv text;
begin
  w := _wie(p_pin);
  if w is null or w = '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  select data into wk from docs where collection = 'weken' and id = p_week;
  select data->>'bvId' into bv from docs where collection = 'keukens' and id = w;
  return jsonb_build_object(
    'keuken', _rij('keukens', w),
    'producten', coalesce((select jsonb_agg(data || jsonb_build_object('id', id)) from docs where collection = 'producten'), '[]'::jsonb),
    'bestelling', _rij('bestellingen', p_week || '_' || w),
    'geleverd', coalesce(wk->'geleverd'->w, '{}'::jsonb),
    'kg', coalesce(wk->'kg'->w, '{}'::jsonb),
    'gefactureerd', coalesce((wk->'gefactureerd'->>bv)::boolean, false),
    'whatsapp', (select data from docs where collection = 'instellingen' and id = 'algemeen')
  );
end $$;

-- Keuken: ontvangen kilo's invullen (alleen voor producten die per kg gaan)
create or replace function public.keuken_kilos(p_pin text, p_week text, p_kg jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text; bv text; wk jsonb; schoon jsonb;
begin
  w := _wie(p_pin);
  if w is null or w = '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  if p_week !~ '^[0-9]{4}-W[0-9]{2}$' or jsonb_typeof(p_kg) <> 'object' then
    return jsonb_build_object('fout', 'Ongeldige gegevens.');
  end if;
  select data->>'bvId' into bv from docs where collection = 'keukens' and id = w;
  select data into wk from docs where collection = 'weken' and id = p_week;
  if coalesce((wk->'gefactureerd'->>bv)::boolean, false) then
    return jsonb_build_object('fout', 'Deze week is al gefactureerd. Vraag de beheerder om de kilo''s aan te passen.');
  end if;
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into schoon
  from jsonb_each(p_kg) e
  where jsonb_typeof(e.value) = 'number' and (e.value::text)::numeric >= 0 and (e.value::text)::numeric < 10000
    and exists(select 1 from docs where collection = 'producten' and id = e.key and coalesce((data->>'perKg')::boolean, false));
  insert into docs(collection, id, data, updated_at)
  values ('weken', p_week, jsonb_build_object('week', p_week, 'kg', jsonb_build_object(w, schoon)), now())
  on conflict (collection, id) do update
    set data = docs.data || jsonb_build_object('kg',
          coalesce(docs.data->'kg', '{}'::jsonb) || jsonb_build_object(w, coalesce(docs.data->'kg'->w, '{}'::jsonb) || schoon)),
        updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.keuken_bestellen(p_pin text, p_week text, p_regels jsonb, p_opmerking text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text;
begin
  w := _wie(p_pin);
  if w is null or w = '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  if p_week !~ '^[0-9]{4}-W[0-9]{2}$' then return jsonb_build_object('fout', 'Ongeldige week.'); end if;
  if jsonb_typeof(p_regels) <> 'object' then return jsonb_build_object('fout', 'Ongeldige bestelling.'); end if;
  insert into docs(collection, id, data, updated_at)
  values ('bestellingen', p_week || '_' || w,
          jsonb_build_object('week', p_week, 'keukenId', w, 'regels', p_regels,
                             'opmerking', left(coalesce(p_opmerking, ''), 500), 'updatedAt', now()),
          now())
  on conflict (collection, id) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Beheer: alles lezen, opslaan, verwijderen en pincodes instellen
create or replace function public.beheer_alles(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if _wie(p_pin) is distinct from '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  return coalesce((select jsonb_object_agg(collection, items) from (
           select collection, jsonb_agg(data || jsonb_build_object('id', id)) items from docs group by collection) t), '{}'::jsonb)
         || jsonb_build_object('pinnen', coalesce((select jsonb_agg(wie) from pincodes where wie <> '__beheer__'), '[]'::jsonb));
end $$;

create or replace function public.beheer_opslaan(p_pin text, p_collection text, p_id text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if _wie(p_pin) is distinct from '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  if p_collection not in ('bvs', 'keukens', 'producten', 'bestellingen', 'weken', 'instellingen') then
    return jsonb_build_object('fout', 'Onbekende lijst.');
  end if;
  if p_id !~ '^[A-Za-z0-9_-]{1,80}$' or jsonb_typeof(p_data) <> 'object' then
    return jsonb_build_object('fout', 'Ongeldige gegevens.');
  end if;
  insert into docs(collection, id, data, updated_at) values (p_collection, p_id, p_data - 'id', now())
  on conflict (collection, id) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.beheer_verwijderen(p_pin text, p_collection text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if _wie(p_pin) is distinct from '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  delete from docs where collection = p_collection and id = p_id;
  if p_collection = 'keukens' then delete from pincodes where wie = p_id; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.beheer_pin_instellen(p_pin text, p_wie text, p_nieuw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  if _wie(p_pin) is distinct from '__beheer__' then return jsonb_build_object('fout', 'Log opnieuw in.'); end if;
  if p_wie = '__beheer__' then
    if p_nieuw !~ '^[0-9]{6,12}$' then return jsonb_build_object('fout', 'De beheerderscode moet uit 6 tot 12 cijfers bestaan.'); end if;
  else
    if not exists(select 1 from docs where collection = 'keukens' and id = p_wie) then return jsonb_build_object('fout', 'Onbekende keuken.'); end if;
    if p_nieuw !~ '^[0-9]{4,12}$' then return jsonb_build_object('fout', 'Een pincode moet uit 4 tot 12 cijfers bestaan.'); end if;
  end if;
  for r in select wie, pin_hash from pincodes where wie <> p_wie loop
    if crypt(p_nieuw, r.pin_hash) = r.pin_hash then
      return jsonb_build_object('fout', 'Deze code is al in gebruik. Kies een andere.');
    end if;
  end loop;
  insert into pincodes(wie, pin_hash) values (p_wie, crypt(p_nieuw, gen_salt('bf')))
  on conflict (wie) do update set pin_hash = excluded.pin_hash;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.status(), public.beheer_eerste_keer(text), public.inloggen(text),
  public.keuken_ophalen(text, text), public.keuken_bestellen(text, text, jsonb, text), public.keuken_kilos(text, text, jsonb),
  public.beheer_alles(text), public.beheer_opslaan(text, text, text, jsonb),
  public.beheer_verwijderen(text, text, text), public.beheer_pin_instellen(text, text, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Startgegevens (overgenomen uit de eerste versie). Bestaande rijen blijven staan.
insert into public.docs(collection, id, data) values
  ('bvs', 'hoofd', '{"naam":"Bowling","hoofd":true,"volgorde":0}'),
  ('bvs', 'bv1',   '{"naam":"Op Eigen Wijze","volgorde":1}'),
  ('bvs', 'bv4',   '{"naam":"Nog Eigen Wijzer","volgorde":1.5}'),
  ('bvs', 'bv2',   '{"naam":"Cheers","volgorde":2}'),
  ('bvs', 'bv3',   '{"naam":"Ons Genoegen","volgorde":3}'),
  ('keukens', 'k-bowling',        '{"naam":"Bowling","bvId":"hoofd","volgorde":0}'),
  ('keukens', 'k-oew',            '{"naam":"Op Eigen Wijze","bvId":"bv1","volgorde":1}'),
  ('keukens', 'k-nogeigenwijzer', '{"naam":"Nog Eigen Wijzer","bvId":"bv4","volgorde":1.5}'),
  ('keukens', 'k-cheers',         '{"naam":"Cheers","bvId":"bv2","volgorde":2}'),
  ('keukens', 'k-onsgenoegen',    '{"naam":"Ons Genoegen","bvId":"bv3","volgorde":3}'),
  ('producten', 'tournedos',     '{"naam":"Tournedos","omschrijving":"gewicht per doos wisselt","prijs":0,"perKg":true,"volgorde":1}'),
  ('producten', 'bavette',       '{"naam":"Bavette","omschrijving":"gewicht per doos wisselt","prijs":0,"perKg":true,"volgorde":2}'),
  ('producten', 'kipfilet',      '{"naam":"Kipfilet","omschrijving":"","prijs":0,"volgorde":3}'),
  ('producten', 'kippendij',     '{"naam":"Kippendij","omschrijving":"","prijs":0,"volgorde":4}'),
  ('producten', 'kipchunks',     '{"naam":"Kip chunks","omschrijving":"","prijs":0,"volgorde":5}'),
  ('producten', 'karaage',       '{"naam":"Karaage kip","omschrijving":"","prijs":0,"volgorde":6}'),
  ('producten', 'yakitori',      '{"naam":"Yakitori spies","omschrijving":"","prijs":0,"volgorde":7}'),
  ('producten', 'pulledchicken', '{"naam":"Pulled chicken","omschrijving":"","prijs":0,"volgorde":8}'),
  ('bestellingen', '2026-W43_k-bowling', '{"week":"2026-W43","keukenId":"k-bowling","regels":{"tournedos":1,"bavette":1,"kipfilet":1,"kippendij":1},"opmerking":""}')
on conflict (collection, id) do nothing;
