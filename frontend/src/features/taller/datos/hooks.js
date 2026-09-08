/**
 * Hooks de datos del módulo. Los componentes no conocen Supabase (§5 del
 * spec): reciben `{ ...datos, cargando, error }` y, cuando aplica,
 * `recargar()`.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import {
  buscarClientes,
  buscarProductos,
  listarEstados,
  listarMarcas,
  listarTecnicos,
} from "./catalogos.js";
import { consultarKpis, consultarOrdenes, consultarPorVencer, contarPorEstado } from "./ordenes.js";

/** Envoltorio común: carga al montar (o cuando cambian `deps`), descarta la
    respuesta si el componente ya se desmontó, y expone `recargar()`. */
function useCargaAsincrona(cargar, deps) {
  const [estado, setEstado] = useState({ datos: null, cargando: true, error: null });
  const vivoRef = useRef(true);

  const ejecutar = useCallback(async () => {
    setEstado((anterior) => ({ ...anterior, cargando: true, error: null }));
    try {
      const datos = await cargar();
      if (vivoRef.current) setEstado({ datos, cargando: false, error: null });
    } catch (error) {
      if (vivoRef.current) setEstado({ datos: null, cargando: false, error });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  useEffect(() => {
    vivoRef.current = true;
    ejecutar();
    return () => {
      vivoRef.current = false;
    };
  }, [ejecutar]);

  return { ...estado, recargar: ejecutar };
}

/** Los estados activos, en orden. CU-03: un INSERT en SQL los hace
    aparecer aquí sin tocar React. */
export function useEstados() {
  const { datos, cargando, error } = useCargaAsincrona(listarEstados, []);
  return { estados: datos ?? [], cargando, error };
}

/** Recuento por estado para las píldoras (incluye "TODAS" si se pide). */
export function useRecuentosPorEstado(codigos) {
  const clave = codigos.join(",");
  const cargar = useCallback(() => contarPorEstado(codigos), [clave]); // eslint-disable-line react-hooks/exhaustive-deps
  const { datos, cargando, error } = useCargaAsincrona(cargar, [clave]);
  return { recuentos: datos ?? {}, cargando, error };
}

export function useOrdenes({ estado = "TODAS", termino = "", pagina = 0, porPagina = 25 } = {}) {
  const cargar = useCallback(
    () => consultarOrdenes({ estado, termino, pagina, porPagina }),
    [estado, termino, pagina, porPagina]
  );
  const { datos, cargando, error, recargar } = useCargaAsincrona(cargar, [
    estado,
    termino,
    pagina,
    porPagina,
  ]);
  return { ordenes: datos?.ordenes ?? [], total: datos?.total ?? 0, cargando, error, recargar };
}

export function useKpis() {
  const { datos, cargando, error, recargar } = useCargaAsincrona(consultarKpis, []);
  return { kpis: datos, cargando, error, recargar };
}

export function usePorVencer({ dias = 30 } = {}) {
  const cargar = useCallback(() => consultarPorVencer({ dias }), [dias]);
  const { datos, cargando, error, recargar } = useCargaAsincrona(cargar, [dias]);
  return { ordenes: datos ?? [], cargando, error, recargar };
}

/** Autocompletado con retardo de 300 ms (§7.2): busca solo cuando el
    usuario deja de teclear. Descarta la respuesta de una búsqueda vieja
    que llega después de una más nueva (carrera de red). */
function useBusquedaConRetardo(buscar) {
  const [termino, setTermino] = useState("");
  const [resultados, setResultados] = useState([]);
  const [buscando, setBuscando] = useState(false);
  const idTimerRef = useRef(null);
  const idPeticionRef = useRef(0);

  useEffect(() => {
    clearTimeout(idTimerRef.current);

    if (termino.trim().length < 2) {
      setResultados([]);
      setBuscando(false);
      return undefined;
    }

    setBuscando(true);
    idTimerRef.current = setTimeout(async () => {
      const miPeticion = ++idPeticionRef.current;
      try {
        const datos = await buscar(termino);
        if (miPeticion === idPeticionRef.current) setResultados(datos);
      } catch {
        if (miPeticion === idPeticionRef.current) setResultados([]);
      } finally {
        if (miPeticion === idPeticionRef.current) setBuscando(false);
      }
    }, 300);

    return () => clearTimeout(idTimerRef.current);
  }, [termino, buscar]);

  return { termino, setTermino, resultados, buscando };
}

export function useBusquedaClientes() {
  const { termino, setTermino, resultados, buscando } = useBusquedaConRetardo(buscarClientes);
  return { termino, setTermino, clientes: resultados, buscando };
}

export function useBusquedaProductos() {
  const { termino, setTermino, resultados, buscando } = useBusquedaConRetardo(buscarProductos);
  return { termino, setTermino, productos: resultados, buscando };
}

export function useMarcas() {
  const { datos, cargando, error } = useCargaAsincrona(listarMarcas, []);
  return { marcas: datos ?? [], cargando, error };
}

export function useTecnicos() {
  const { datos, cargando, error } = useCargaAsincrona(listarTecnicos, []);
  return { tecnicos: datos ?? [], cargando, error };
}
