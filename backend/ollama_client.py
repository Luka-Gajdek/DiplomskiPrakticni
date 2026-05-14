import httpx
import json
import re

OLLAMA_BASE_URL = "http://localhost:11434"
MODEL_NAME = "llama3:8b"

INTENT_PROMPT = """You are an intent classifier for a Business Central ERP assistant.

Classify the user message into exactly one of these intents:
- predict_sales   : user wants a sales forecast or prediction for an item
- stock_duration  : user asks how long the current stock/inventory of an item will last
- item_info       : user asks about an item, product, stock, inventory, price
- vacation        : user asks about vacation days, holidays, absence, leave for an employee
- customer        : user asks about a customer or client
- late_payment    : user asks whether an invoice or customer will pay on time, payment risk, late payment prediction
- show_image      : user wants to see a picture or photo of an item
- chat            : anything else (greetings, general questions, etc.)

For the parameter, extract ONLY the core identifying value — not surrounding words:
- For items: extract only the item name or number (e.g. "Berlin Chair", "1900-S"), never phrases like "current stash of Berlin chairs" or "the tokyo chair we have"
- For employees: extract only the person's name
- For customers: extract only the customer name or number

For predict_sales, also extract the number of forecast days if mentioned (default to 30 if not specified).
For vacation, also extract the year if mentioned (default to 0 if not specified).

Examples:
"how long can we expect current stash of berlin chairs to last?" -> {"intent": "stock_duration", "parameter": "berlin chairs", "days": 30, "year": 0}
"predict sales for item 1900-S for next 60 days" -> {"intent": "predict_sales", "parameter": "1900-S", "days": 60, "year": 0}
"can you predict sales for 1896-S for next 100 days?" -> {"intent": "predict_sales", "parameter": "1896-S", "days": 100, "year": 0}
"predict sales for 1900-S" -> {"intent": "predict_sales", "parameter": "1900-S", "days": 30, "year": 0}
"how much of tokyo chair do we have?" -> {"intent": "item_info", "parameter": "tokyo chair", "days": 30, "year": 0}
"how many vacation days does John Smith have left?" -> {"intent": "vacation", "parameter": "John Smith", "days": 30, "year": 0}
"list all absences for Terry Dodds in 2027" -> {"intent": "vacation", "parameter": "Terry Dodds", "days": 30, "year": 2027}
"how many sick days did Jane in 2025?" -> {"intent": "vacation", "parameter": "Jane", "days": 30, "year": 2025}
"will Adatum Corporation pay their invoices on time?" -> {"intent": "late_payment", "parameter": "Adatum Corporation", "days": 30, "year": 0}
"what is the payment risk for customer 10000?" -> {"intent": "late_payment", "parameter": "10000", "days": 30, "year": 0}
"predict late payments" -> {"intent": "late_payment", "parameter": "", "days": 30, "year": 0}
"can you show me a picture of the tokyo chair we have?" -> {"intent": "show_image", "parameter": "tokyo chair", "days": 30, "year": 0}
"show me a photo of item 1900-S" -> {"intent": "show_image", "parameter": "1900-S", "days": 30, "year": 0}

Respond ONLY with a JSON object, no explanation:
{"intent": "<intent>", "parameter": "<parameter>", "days": <number>, "year": <number>}

User message: """

SYSTEM_PROMPT = (
    "You are a helpful Business Central ERP assistant. "
    "Answer questions concisely and accurately using plain prose — no bullet points, no asterisks, no markdown formatting. "
    "When context data is provided (JSON), use it to give precise answers but never mention JSON field names, variable names, or technical flags from the data. "
    "For item data, inventory always means quantity in stock (units), never monetary value; never use currency symbols for inventory. "
    "Use currency only when describing prices or amounts (for example unit price). "
    "Translate data into natural human language. For example, do not say 'will_be_late is true' — say 'is expected to be paid late'. "
    "Keep answers short and professional."
)


async def detect_intent(message: str, history: list = None) -> dict:
    """Ask Llama3 to classify the user's intent and extract the key parameter."""
    prompt = INTENT_PROMPT
    if history:
        recent = history[-4:]  # last 2 turns
        prompt += "Recent conversation:\n"
        for msg in recent:
            role_label = "User" if msg.get("role") == "user" else "Assistant"
            prompt += f"{role_label}: {msg.get('content', '')}\n"
        prompt += "\nNow classify this message (resolve any references using the conversation above):\n"
    prompt += message

    payload = {
        "model": MODEL_NAME,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0.0,
            "num_predict": 64,
        }
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(f"{OLLAMA_BASE_URL}/api/generate", json=payload)
        response.raise_for_status()
        raw = response.json().get("response", "").strip()

    # Extract JSON from response
    match = re.search(r'\{.*?\}', raw, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
        except json.JSONDecodeError:
            pass

    return {"intent": "chat", "parameter": "", "days": 30}


async def generate(message: str, context: str = "", history: list = None) -> str:
    """Send a prompt to Ollama and return the response text."""
    prompt_parts = []

    if context:
        prompt_parts.append(f"Context data from Business Central:\n{context}\n")

    if history:
        prompt_parts.append("Previous conversation:")
        for msg in history:
            role_label = "User" if msg.get("role") == "user" else "Assistant"
            prompt_parts.append(f"{role_label}: {msg.get('content', '')}")
        prompt_parts.append("")

    prompt_parts.append(f"User: {message}\nAssistant:")

    full_prompt = "\n".join(prompt_parts)

    payload = {
        "model": MODEL_NAME,
        "prompt": full_prompt,
        "system": SYSTEM_PROMPT,
        "stream": False,
        "options": {
            "temperature": 0.3,
            "num_predict": 512,
        }
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json=payload
        )
        response.raise_for_status()
        data = response.json()
        return data.get("response", "").strip()
