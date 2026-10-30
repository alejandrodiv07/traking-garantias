#!/usr/bin/env bash
# Verifica el historial de migraciones: nombres válidos y sin versiones
# duplicadas. Se usa en CI (Tarea 3 del plan).
#
# Uso: bash scripts/verificar-migraciones.sh [directorio]
#   Directorio por defecto: supabase/migrations
# Sale 1 si un nombre no cumple `^[0-9]{14}_[a-z0-9_]+\.sql$` o si dos
# archivos comparten la versión (los 14 primeros caracteres).
set -euo pipefail

dir="${1:-supabase/migrations}"
if [ ! -d "$dir" ]; then
  echo "verificar-migraciones: el directorio no existe: $dir" >&2
  exit 1
fi

salida=0
versiones=""

for f in "$dir"/*.sql; do
  nombre=$(basename "$f")
  if ! printf '%s' "$nombre" | grep -qE '^[0-9]{14}_[a-z0-9_]+\.sql$'; then
    echo "verificar-migraciones: nombre inválido: $nombre"
    salida=1
    continue
  fi
  version=${nombre:0:14}
  if printf '%s\n' "$versiones" | grep -qx "$version"; then
    echo "verificar-migraciones: versión duplicada $version: $nombre"
    salida=1
  fi
  versiones="$versiones$version"$'\n'
done

if [ "$salida" -eq 0 ]; then
  echo "verificar-migraciones: OK ($(printf '%s\n' "$versiones" | grep -c .) migraciones en $(printf '%s' "$(basename "$dir")"))"
fi
exit "$salida"