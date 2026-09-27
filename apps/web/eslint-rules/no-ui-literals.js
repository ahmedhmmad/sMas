// F1.7 — لا نصوص معروضة للمستخدم داخل المكونات: كل نص من فهرس الترجمة عبر t(key).
// يُبلَّغ: نص بين الوسوم، وقيم الخصائص المعروضة (placeholder، title، aria-label، alt، label…) حرفيةً أو
// تعبيراً حرفياً، والتعبيرات الحرفية كأبناء JSX. لا يُبلَّغ: className، المسارات، المفاتيح، رموز الـAPI، data-testid.
const USER_FACING_ATTRS = new Set([
  "placeholder", "title", "alt", "label", "aria-label", "aria-description", "aria-placeholder", "aria-roledescription",
]);
const HAS_LETTER = /\p{L}/u;

function literalText(node) {
  if (!node) return null;
  if (node.type === "Literal" && typeof node.value === "string") return node.value;
  if (node.type === "TemplateLiteral") return node.quasis.map((q) => q.value.cooked).join("");
  if (node.type === "JSXExpressionContainer") return literalText(node.expression);
  return null;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "user-facing text must come from the translation catalog" },
    messages: { literal: "User-facing text must come from t(key), not a literal: {{text}}" },
    schema: [],
  },
  create(context) {
    const report = (node, text) =>
      context.report({ node, messageId: "literal", data: { text: text.trim().slice(0, 40) } });
    return {
      JSXText(node) {
        if (HAS_LETTER.test(node.value)) report(node, node.value);
      },
      JSXAttribute(node) {
        const name = node.name.type === "JSXNamespacedName" ? node.name.name.name : node.name.name;
        if (!USER_FACING_ATTRS.has(name)) return;
        const text = literalText(node.value);
        if (text && HAS_LETTER.test(text)) report(node, text);
      },
      JSXExpressionContainer(node) {
        if (node.parent?.type !== "JSXElement" && node.parent?.type !== "JSXFragment") return;
        const text = literalText(node.expression);
        if (text && HAS_LETTER.test(text)) report(node, text);
      },
    };
  },
};
