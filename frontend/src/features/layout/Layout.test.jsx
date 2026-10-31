// Layout con barra lateral (docs/diseno-ui/README.md §2): destinos como
// NavLink con URL real, usuario y cierre de sesión.
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

const salir = vi.fn();
vi.mock("../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ perfil: { email: "ada@prime.com" }, salir }),
}));

import Layout from "./Layout.jsx";

const montar = (ruta) =>
  render(
    <MemoryRouter initialEntries={[ruta]}>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/garantias/*" element={<p>contenido garantías</p>} />
          <Route path="/taller/*" element={<p>contenido taller</p>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  );

describe("Layout", () => {
  it("enlaza Garantías y Taller con URL real y pinta el contenido de la ruta", () => {
    montar("/garantias");
    expect(screen.getByRole("link", { name: /Garantías/ })).toHaveAttribute("href", "/garantias");
    expect(screen.getByRole("link", { name: /Taller/ })).toHaveAttribute("href", "/taller");
    expect(screen.getByText("contenido garantías")).toBeTruthy();
  });

  it.each([
    ["/garantias", "Garantías"],
    ["/garantias/consulta", "Garantías"],
    ["/taller/abc", "Taller"],
  ])("en %s solo el destino %s lleva aria-current", (ruta, activo) => {
    montar(ruta);
    const marcados = screen
      .getAllByRole("link")
      .filter((a) => a.getAttribute("aria-current") === "page");
    expect(marcados).toHaveLength(1);
    expect(marcados[0]).toHaveTextContent(activo);
  });

  it("muestra el correo y cierra sesión", async () => {
    montar("/taller");
    expect(screen.getByText("ada@prime.com")).toBeTruthy();
    await userEvent.setup().click(screen.getByRole("button", { name: /Cerrar sesión/ }));
    expect(salir).toHaveBeenCalled();
  });

  it("muestra los siete destinos del diseño", () => {
    montar("/garantias");
    const nombres = ["Garantías", "Taller", "Entregas", "Inventario", "Reportes", "Clientes", "Notificaciones"];
    for (const n of nombres) expect(screen.getByRole("link", { name: n })).toBeTruthy();
  });

  it("alterna el tema claro/oscuro y lo recuerda", async () => {
    document.documentElement.dataset.theme = "dark";
    montar("/garantias");
    await userEvent.setup().click(screen.getByRole("button", { name: "Cambiar a tema claro" }));
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(localStorage.getItem("pt.tema")).toBe("light");
    expect(screen.getByRole("button", { name: "Cambiar a tema oscuro" })).toBeTruthy();
  });

  it("pliega la barra a iconos y recuerda la preferencia", async () => {
    montar("/garantias");
    await userEvent.setup().click(screen.getByRole("button", { name: "Contraer menú" }));
    expect(document.querySelector(".app")).toHaveClass("plegada");
    expect(localStorage.getItem("pt.plegada")).toBe("1");
  });

  it.each([
    ["/garantias", "Garantías | Prime Telecom"],
    ["/garantias/consulta", "Garantías | Prime Telecom"],
    ["/taller/abc", "Taller | Prime Telecom"],
  ])("en %s el título de la pestaña es «%s»", (ruta, titulo) => {
    document.title = "Prime Telecom | Iniciar sesión";
    montar(ruta);
    expect(document.title).toBe(titulo);
  });

  it("en una subpágina la barra superior no repite la miga que ya trae la página", () => {
    montar("/garantias/consulta");
    expect(screen.queryByText(/Prime Telecom \//)).toBeNull();
  });

  it("en la página raíz del módulo la barra sí lleva la miga", () => {
    montar("/garantias");
    expect(screen.getAllByText(/Prime Telecom \//).length).toBeGreaterThan(0);
  });

  it("en móvil abre y cierra el cajón", async () => {
    montar("/garantias");
    const u = userEvent.setup();
    await u.click(screen.getByRole("button", { name: "Abrir menú" }));
    expect(document.querySelector(".side")).toHaveClass("abierta");
    await u.keyboard("{Escape}");
    expect(document.querySelector(".side")).not.toHaveClass("abierta");
  });
});
