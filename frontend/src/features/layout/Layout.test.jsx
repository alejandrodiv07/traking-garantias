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
});
