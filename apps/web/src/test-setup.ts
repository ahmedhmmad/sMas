import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

// Testing Library لا ينظف تلقائياً بلا globals في Vitest
afterEach(cleanup);
