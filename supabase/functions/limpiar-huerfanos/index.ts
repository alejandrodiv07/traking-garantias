// =====================================================================
//  Edge Function: limpiar-huerfanos  (spec §5.7, Tarea 14 del plan)
//  Prime Telecom · Track Garantía
//
//  Lo único que borra archivos del taller, y borra SOLO del
//  almacenamiento: objetos del bucket `registros` sin fila en
//  `adjuntos` y con más de 24 horas (para no tocar subidas en curso).
//  Las filas de `adjuntos` nunca se tocan aquí.
//
//  ---------------------------------------------------------------------
//  AUTORIZACIÓN: el disparo lo hace el job diario de pg_cron vía pg_net,
//  desde la base. La única prueba es la cabecera `x-cron-secret`
//  contra el secreto LIMPIEZA_SECRET (`supabase secrets set`). No hay
//  sesión de usuario que validar: quien llama es el propio proyecto.
//
//  RESPUESTA (contrato probado en index.test.ts):
//    { "huerfanos": n, "borrados": n, "simulacion": bool }
//  Con ?simular=1: mismo cuerpo (más `nombres`), y NO se borra nada.
//  =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const JSON_HEADERS = { "Content-Type": "application/json" };

function respuesta(cuerpo: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(cuerpo), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  // Solo el job programado: POST con el secreto de cron.
  if (req.method !== "POST") {
    return respuesta({ error: "Método no admitido" }, 405);
  }
  const secreto = Deno.env.get("LIMPIEZA_SECRET");
  if (!secreto || req.headers.get("x-cron-secret") !== secreto) {
    return respuesta({ error: "No autorizado" }, 401);
  }

  const simular = new URL(req.url).searchParams.get("simular") !== null;

  // service_role: la limpieza es una tarea del sistema, no de un usuario.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL") as string,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") as string,
  );

  // La base enumera (anti-join con la tabla adjuntos); nunca borra filas.
  const { data, error } = await admin.rpc("listar_huerfanos", {
    p_gracia: "24 hours",
  });
  if (error) {
    console.error("listar_huerfanos:", error.message);
    return respuesta({ error: "La base no pudo listar huérfanos" }, 500);
  }

  const nombres = (data ?? []).map((fila: { nombre: string }) => fila.nombre);

  if (simular) {
    return respuesta({
      huerfanos: nombres.length,
      borrados: 0,
      simulacion: true,
      nombres: nombres,
    });
  }

  if (nombres.length === 0) {
    return respuesta({ huerfanos: 0, borrados: 0, simulacion: false });
  }

  const { error: errorBorrar } = await admin.storage
    .from("registros")
    .remove(nombres);
  if (errorBorrar) {
    console.error("storage.remove:", errorBorrar.message);
    return respuesta({ error: "El almacenamiento no dejó borrar los huérfanos" }, 500);
  }

  return respuesta({
    huerfanos: nombres.length,
    borrados: nombres.length,
    simulacion: false,
  });
});