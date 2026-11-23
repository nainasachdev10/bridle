"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/** Top navigation; the current section gets a vermilion knot above it. */
export function Nav() {
  const path = usePathname();
  const inVaults = path === "/" || path?.startsWith("/vault");
  return (
    <nav className="nav" aria-label="Main">
      <Link href="/#vaults" className={inVaults ? "active" : undefined}>Vaults</Link>
      <Link href="/#how">How it works</Link>
      <Link href="/#scoring">Scoring</Link>
    </nav>
  );
}
