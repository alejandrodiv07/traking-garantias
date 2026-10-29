#!/usr/bin/env bash
# Ejecutor de pruebas SQL para un Postgres 17 en Docker.
#
# Uso: bash supabase/tests/run.sh [archivo.sql …]
#   - Con argumentos: corre solo esos archivos de prueba.
#   - Sin argumentos: corre todos los archivos de prueba numerados (01…*)
#     en orden, saltando el harness (00_*) y los archivos de copia (_*).
#
# Cada archivo corre contra una BASE DE DATOS NUEVA (los scripts de prueba
# llevan sus propias semillas y no conviven en una misma base). Por cada
# prueba imprime `PASA n · FALLA m` y sale con código 1 si alguna prueba
# registró un fallo, no registró ningún `PASA`, o su ejecución falló.
set -euo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
container=""

al_salir() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
}
trap al_salir EXIT

container=$(docker run --rm -d -e POSTGRES_PASSWORD=postgres postgres:17)
echo ">> Postgres 17 en Docker ($container); esperando a que esté listo…"
listo=false
for _ in $(seq 1 60); do
  if docker exec "$container" pg_isready -U postgres -q; then listo=true; break; fi
  sleep 1
done
if [ "$listo" = false ]; then
  echo ">> ERROR: Postgres no respondió a tiempo" >&2
  exit 1
fi

psql_db() { # psql_db <base> [args…]
  docker exec -i -e PGPASSWORD=postgres "$container" \
    psql -U postgres -d "$1" "${@:2}"
}

# Roles que Supabase crea por su cuenta y que migraciones y pruebas emulan.
docker exec -i -e PGPASSWORD=postgres "$container" \
  psql -U postgres -q <<'SQL' >/dev/null
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
SQL

# Aplica el harness, las migraciones y el seed (en la base dada, con cortes estrictos).
preparar_base() {
  psql_db "$1" -v ON_ERROR_STOP=1 -f - \
    < "$tests_dir/00_harness_supabase_local.sql" >/dev/null
  for m in "$tests_dir"/../migrations/*.sql; do
    case "$(basename "$m")" in _*) continue ;; esac   # copias, nunca se aplican
    psql_db "$1" -v ON_ERROR_STOP=1 -f - < "$m" >/dev/null
  done
  if [ -f "$tests_dir/../seed.sql" ]; then
    psql_db "$1" -v ON_ERROR_STOP=1 -f - < "$tests_dir/../seed.sql" >/dev/null
    # El seed deja el catálogo usable: una base sin productos es un error.
    n_productos=$(psql_db "$1" -tA -c "SELECT count(*) FROM public.productos")
    if [ "$n_productos" -eq 0 ]; then
      echo ">> ERROR: el seed no dejó productos en la base" >&2
      exit 1
    fi
  fi
}

if [ $# -gt 0 ]; then
  pruebas=("$@")
else
  pruebas=()
  for f in "$tests_dir"/[0-9]*.sql; do
    case "$(basename "$f")" in 00_*) continue ;; esac
    pruebas+=("$f")
  done
fi

if [ ${#pruebas[@]} -eq 0 ]; then
  echo ">> ERROR: no hay pruebas que correr" >&2
  exit 1
fi

echo
salida=0
for f in "${pruebas[@]}"; do
  nombre=$(basename "$f")
  base="pttest_$$_$RANDOM"
  psql_db postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$base\"" \
    -c "CREATE DATABASE \"$base\"" >/dev/null
  preparar_base "$base"

  # Las pruebas contienen errores previstos (BEGIN; error; ROLLBACK), así
  # que corren con ON_ERROR_STOP desactivado: el juez es el recuento.
  if ! contenido=$(psql_db "$base" -f - < "$f" 2>&1); then
    echo "   ¡El archivo terminó con un error de ejecución!"
    salida=1
  fi
  pasa=$(printf '%s\n' "$contenido" | grep -c 'NOTICE: *PASA' || true)
  falla=$(printf '%s\n' "$contenido" | grep -c -F '*FALLA*' || true)
  printf '%-34s · PASA %3d · FALLA %3d\n' "$nombre" "$pasa" "$falla"
  if [ "$falla" -gt 0 ]; then
    printf '%s\n' "$contenido" | grep -F '*FALLA*' | sed 's/^/      /'
  fi
  if [ "$pasa" -eq 0 ] || [ "$falla" -gt 0 ]; then
    salida=1
    printf '%s\n' "$contenido" | tail -n 20 | sed 's/^/      /'
  fi
  psql_db postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE \"$base\"" >/dev/null
done

if [ "$salida" -ne 0 ]; then
  echo ">> HAY FALLOS"
  exit 1
fi
echo ">> TODAS LAS PRUEBAS PASAN"