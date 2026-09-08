/**
 * Documentos adjuntos a una orden.
 *
 * Sube DESPUÉS de crear_orden(): Storage no participa de una transacción
 * SQL (ADR-012). Ningún documento es obligatorio; si uno falla, se avisa
 * por archivo -- nunca se revierte la orden ya creada, porque revertirla
 * perdería el token de consulta de un solo uso (ADR-003, ADR-011).
 */
import { supabase } from "../../../lib/supabaseClient.js";

const BUCKET = "documentos-garantias";

/** Espejo de los límites del bucket y del CHECK de `documentos_garantia`
    (migración `20260908000006`). Si alguna vez divergen, manda la base --
    esto es solo para dar el error ANTES de gastar una subida. */
export const TAMANO_MAXIMO_BYTES = 10 * 1024 * 1024;
export const MAX_ARCHIVOS_POR_ORDEN = 5;
export const TIPOS_MIME_PERMITIDOS = Object.freeze(["application/pdf", "image/jpeg", "image/png"]);

export const TIPOS_DOCUMENTO = Object.freeze([
  { codigo: "FACTURA", etiqueta: "Factura" },
  { codigo: "FOTO_EQUIPO", etiqueta: "Foto del equipo" },
  { codigo: "OTRO", etiqueta: "Otro" },
]);

function extensionDe(nombreArchivo) {
  const m = /\.([a-zA-Z0-9]+)$/.exec(nombreArchivo ?? "");
  return m ? m[1].toLowerCase() : "bin";
}

function idAleatorio() {
  // crypto.randomUUID existe en todo navegador moderno servido por HTTPS
  // (o localhost); si alguna vez falta, un timestamp+random basta para un
  // nombre de archivo que solo necesita no colisionar.
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

/**
 * Sube un archivo y registra su metadato. Devuelve siempre
 * `{ ok, datos } | { ok: false, error }`, nunca lanza: el llamador debe
 * poder seguir con el resto de la lista aunque este falle.
 */
export async function subirDocumento({ ordenId, tipo, archivo, usuarioId }) {
  if (archivo.size > TAMANO_MAXIMO_BYTES) {
    return { ok: false, error: { mensaje: `"${archivo.name}" pesa más de 10 MB.` } };
  }
  if (!TIPOS_MIME_PERMITIDOS.includes(archivo.type)) {
    return { ok: false, error: { mensaje: `"${archivo.name}" no es PDF, JPG ni PNG.` } };
  }

  // Convención de path del bucket (migración `20260908000006`): el primer
  // segmento es la orden, y es lo único que las políticas de Storage
  // necesitan para razonar sobre a qué orden pertenece el objeto.
  const ruta = `${ordenId}/${idAleatorio()}.${extensionDe(archivo.name)}`;

  const subida = await supabase.storage.from(BUCKET).upload(ruta, archivo, {
    contentType: archivo.type,
    upsert: false,
  });
  if (subida.error) {
    return { ok: false, error: { mensaje: `No se pudo subir "${archivo.name}". Reinténtalo.` } };
  }

  const { data, error } = await supabase
    .from("documentos_garantia")
    .insert({
      garantia_id: ordenId,
      tipo,
      ruta_storage: ruta,
      nombre_original: archivo.name,
      tamano_bytes: archivo.size,
      subido_por: usuarioId,
    })
    .select("id, tipo, nombre_original, tamano_bytes, creado_en")
    .single();

  if (error) {
    // El binario ya quedó en Storage pero sin metadato: se limpia para no
    // dejar un objeto huérfano que nadie puede ver desde la aplicación.
    await supabase.storage.from(BUCKET).remove([ruta]);
    return { ok: false, error: { mensaje: `No se pudo registrar "${archivo.name}". Reinténtalo.` } };
  }

  return { ok: true, datos: data };
}

/**
 * Sube una lista de adjuntos pendientes, uno por uno, SIN abortar en el
 * primer fallo (ADR-012: la orden ya existe, cada archivo se avisa aparte).
 * `pendientes` es `[{ tipo, archivo }]`.
 */
export async function subirDocumentos({ ordenId, pendientes, usuarioId }) {
  const resultados = [];
  for (const p of pendientes) {
    // eslint-disable-next-line no-await-in-loop -- deliberado: subidas
    // secuenciales, no en paralelo, para no saturar la conexión del
    // mostrador con 5 uploads simultáneos de una vez.
    const resultado = await subirDocumento({
      ordenId,
      tipo: p.tipo,
      archivo: p.archivo,
      usuarioId,
    });
    resultados.push({ ...resultado, nombreArchivo: p.archivo.name });
  }
  return resultados;
}

/** URL firmada de corta duración -- el bucket es privado, no existe una
    URL fija que se pueda guardar ni compartir. */
export async function rutaFirmada(rutaStorage, segundosValidez = 60) {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(rutaStorage, segundosValidez);
  if (error) throw error;
  return data.signedUrl;
}
