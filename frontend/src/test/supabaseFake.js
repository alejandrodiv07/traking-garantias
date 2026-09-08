/**
 * Doble de prueba de la cadena de PostgREST/supabase-js.
 *
 * `datos/*.js` encadena `.select().eq().order()...` y al final hace
 * `await` sobre el resultado -- eso es lo único que este doble necesita
 * imitar: cada método de la cadena se devuelve a sí mismo, y el objeto
 * completo es "thenable" (implementa `.then`), así que `await consulta`
 * dispara la resolución con el resultado que el test configuró.
 *
 * No es un mock de Supabase en general -- es exactamente la superficie que
 * usan `catalogos.js`, `ordenes.js` y `documentos.js`, ni una línea más.
 *
 * ---------------------------------------------------------------------------
 * POR QUÉ LA CADENA REGISTRA SUS LLAMADAS
 * ---------------------------------------------------------------------------
 * La versión anterior se tragaba los argumentos: `eq: () => encadenable`.
 * Con eso se podía probar que una fila se normaliza bien, pero NO que el
 * filtro por estado llegue a la consulta, ni que la búsqueda mire las seis
 * columnas, ni que la paginación pida el rango correcto -- es decir, no se
 * podía probar nada de lo que el operador ve cuando pulsa una píldora o
 * escribe en el buscador. Un doble que descarta los argumentos convierte
 * "filtrar" en una función sin comportamiento observable.
 *
 * Ahora cada eslabón anota `[metodo, ...args]` en `consulta.llamadas`, y
 * `consulta.argumentosDe("eq")` devuelve los argumentos de esa llamada.
 * El contrato de antes no cambia: los métodos siguen devolviendo la cadena
 * y el objeto sigue siendo thenable, así que las pruebas existentes
 * funcionan sin tocarlas.
 */
export function crearConsultaFalsa(resultado) {
  const llamadas = [];

  const registrar =
    (nombre) =>
    (...args) => {
      llamadas.push([nombre, ...args]);
      return encadenable;
    };

  const encadenable = {
    llamadas,
    /** Argumentos de la primera llamada a `nombre`, o `undefined` si no se llamó. */
    argumentosDe(nombre) {
      const llamada = llamadas.find(([n]) => n === nombre);
      return llamada ? llamada.slice(1) : undefined;
    },
    /** ¿Se invocó este eslabón de la cadena? */
    seLlamo(nombre) {
      return llamadas.some(([n]) => n === nombre);
    },
    select: registrar("select"),
    insert: registrar("insert"),
    eq: registrar("eq"),
    or: registrar("or"),
    ilike: registrar("ilike"),
    order: registrar("order"),
    range: registrar("range"),
    limit: registrar("limit"),
    gte: registrar("gte"),
    lte: registrar("lte"),
    single: (...args) => {
      llamadas.push(["single", ...args]);
      return Promise.resolve(resultado);
    },
    then: (resolver, rechazador) => Promise.resolve(resultado).then(resolver, rechazador),
  };
  return encadenable;
}

/** Doble del cliente completo: `from()`, `rpc()` y `storage.from()`. Cada
    prueba configura los `vi.fn()` que necesita con `mockReturnValue`/
    `mockResolvedValue`. */
export function crearClienteFalso() {
  return {
    from: () => crearConsultaFalsa({ data: null, error: null }),
    rpc: () => Promise.resolve({ data: null, error: null }),
    storage: {
      from: () => ({
        upload: () => Promise.resolve({ data: null, error: null }),
        remove: () => Promise.resolve({ data: null, error: null }),
        createSignedUrl: () => Promise.resolve({ data: { signedUrl: "" }, error: null }),
      }),
    },
  };
}
