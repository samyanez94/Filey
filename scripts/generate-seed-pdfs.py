"""Regenerate the fictional Filey PDF fixtures. Requires reportlab."""
from pathlib import Path
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak

ROOT = Path(__file__).parent / "seed-assets"
STYLES = getSampleStyleSheet()
STYLES.add(ParagraphStyle(name="TitleBlue", fontName="Helvetica-Bold", fontSize=27, leading=32, textColor=colors.HexColor("#163759"), spaceAfter=14))
STYLES.add(ParagraphStyle(name="SectionBlue", fontName="Helvetica-Bold", fontSize=13, leading=18, textColor=colors.HexColor("#245b86"), spaceBefore=18, spaceAfter=8))
STYLES["BodyText"].fontSize = 11
STYLES["BodyText"].leading = 17
STYLES["BodyText"].spaceAfter = 10

def p(text): return Paragraph(text, STYLES["BodyText"])
def h(text): return Paragraph(text, STYLES["SectionBlue"])
def table(rows):
    result = Table([[p(str(cell)) for cell in row] for row in rows], colWidths=[330, 150])
    result.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#eaf1f7")),
        ("VALIGN",(0,0),(-1,-1),"TOP"),
        ("LEFTPADDING",(0,0),(-1,-1),12),
        ("RIGHTPADDING",(0,0),(-1,-1),12),
        ("TOPPADDING",(0,0),(-1,-1),8),
        ("BOTTOMPADDING",(0,0),(-1,-1),4),
        ("LINEBELOW",(0,0),(-1,-1),0.4,colors.HexColor("#d8e1e8")),
    ]))
    return result

def footer(canvas, doc):
    canvas.setStrokeColor(colors.HexColor("#d8e1e8"))
    canvas.line(60,48,552,48)
    canvas.setFont("Helvetica",8)
    canvas.setFillColor(colors.HexColor("#667788"))
    canvas.drawString(60,33,"FILEY DEMO  /  Fictional sample content")
    canvas.drawRightString(552,33,f"Page {doc.page}")

def document(name, subtitle, blocks):
    doc = SimpleDocTemplate(str(ROOT / (name + ".pdf")), pagesize=(612,792),
        rightMargin=60,leftMargin=60,topMargin=58,bottomMargin=65,
        title=name,author="Filey", invariant=1)
    doc.build([Paragraph(name, STYLES["TitleBlue"]),p(subtitle),Spacer(1,8)]+blocks,
        onFirstPage=footer,onLaterPages=footer)

ROOT.mkdir(exist_ok=True)
document("Sample Resume", "Jordan Rivera | iOS Developer<br/>jordan.rivera@example.com | Portland, Oregon", [
    h("Profile"),p("iOS developer who enjoys building approachable tools for everyday tasks. Experienced with SwiftUI, asynchronous networking, and testing small, dependable features."),
    h("Experience"),p("<b>Northstar Studio - iOS Developer</b><br/>2023 - 2026"),
    p("Built a document browser with nested navigation, PDF previews, and accessible loading states. Introduced URLSession test doubles to verify network failures without live services."),
    p("<b>Cedar Labs - Software Developer</b><br/>2021 - 2023"),
    p("Maintained a scheduling app and improved its offline experience. Worked with designers to simplify navigation and support larger text sizes."),
    h("Selected project"),p("<b>Pocket Library</b><br/>A personal reading organizer with document import, search, and local bookmarks. Designed a small API client with explicit cancellation and retry behavior."),
    h("Skills"),p("Swift, SwiftUI, UIKit, URLSession, Swift Testing, Git, SQL, REST APIs"),
    h("Education"),p("B.S. Computer Science | Cascadia Example College | 2021")
])
document("Apartment Checklist", "Moving day plan | October 24, 2026", [
    h("One week before"),p("[ ] Confirm elevator access and parking with building management.<br/>[ ] Transfer utilities and update the mailing address.<br/>[ ] Pack an overnight bag, medication, chargers, and a change of clothes."),
    h("Before leaving"),p("[ ] Photograph each room after cleaning.<br/>[ ] Check cupboards, closets, and the storage locker.<br/>[ ] Record meter readings and return all keys."),
    h("At the new apartment"),p("[ ] Test smoke alarms and locate the circuit breaker.<br/>[ ] Check taps, appliances, windows, and door locks.<br/>[ ] Photograph existing damage and send notes to management."),
    h("First evening"),p("[ ] Assemble the bed and unpack bathroom essentials.<br/>[ ] Connect Wi-Fi and charge devices.<br/>[ ] Flatten boxes and keep exits clear."),
    h("Notes"),p("Keep the signed lease, move-in inspection, and utility confirmations together in Documents. Bring a tape measure before ordering furniture.")
])
document("Coffee Receipt", "Juniper Coffee | Receipt JC-1042<br/>October 18, 2026 at 09:14", [
    h("Order"),table([["Item","Amount"],["Oat latte","$5.50"],["Blueberry muffin","$3.75"],["Subtotal","$9.25"],["Tax","$0.74"],["Tip","$1.50"],["Total paid","$11.49"]]),
    h("Payment"),p("Demo card ending 0000<br/>Pickup: counter | Served by: Alex"),
    h("Thank you"),p("A quiet morning, a warm drink, and a fresh start.<br/>This is a fictional receipt for preview testing; no purchase was made.")
])
document("Office Supplies", "Cedar Paper Co. | Receipt CP-2086<br/>October 19, 2026 at 14:32", [
    h("Order"),table([["Item","Amount"],["2 dotted notebooks at $8.00","$16.00"],["Black gel pen set","$7.50"],["Desk organizer","$18.00"],["Subtotal","$41.50"],["Tax","$3.32"],["Total paid","$44.82"]]),
    h("Payment"),p("Demo card ending 0000<br/>Order type: in-store"),
    h("Purchase notes"),p("Supplies for the home workspace. Keep one notebook for interview practice and the other for project sketches. This fictional receipt has no financial value.")
])
document("Weekend Itinerary", "A relaxed weekend in Portland | October 23 - 25, 2026", [
    h("Friday - arrive and settle in"),table([["Time","Plan"],["16:00","Check in"],["17:30","Neighborhood walk"],["19:00","Dinner near hotel"]]),
    p("Leave the first evening flexible. Unpack, find a nearby grocery store, and check the forecast before choosing tomorrow's route."),
    h("Saturday - parks and bookshops"),table([["Time","Plan"],["08:30","Breakfast"],["10:00","Park walk"],["13:00","Lunch break"],["15:00","Bookshop visit"],["18:30","Dinner"]]),
    h("Bring along"),p("Comfortable shoes, a rain jacket, a reusable water bottle, and a charged phone. Save the hotel confirmation before leaving Wi-Fi."),
    PageBreak(),h("Sunday - a slow morning"),table([["Time","Plan"],["09:00","Coffee and breakfast"],["10:30","Pack and check room"],["11:00","Check out"],["12:00","Travel home"]]),
    h("Rainy-day alternative"),p("Swap the park walk for an indoor museum visit. Keep travel time between stops short and leave room for a late lunch."),
    h("Budget"),table([["Category","Estimate"],["Hotel, two nights","$280"],["Meals and coffee","$120"],["Local transport","$35"],["Activities","$40"],["Total","$475"]]),
    h("Before heading home"),p("Check outlets for chargers, return the room key, and save receipts. This itinerary is fictional practice content, not a booking or current travel recommendation.")
])
document("Hotel Confirmation", "Harbor House - Fictional Guesthouse<br/>Confirmation: DEMO-4826", [
    h("Your stay"),table([["Detail","Reservation"],["Guest","Jordan Rivera"],["Check-in","October 23, 2026"],["Check-out","October 25, 2026"],["Room","Standard queen"],["Guests","1 adult"],["Nights","2"]]),
    h("Rate summary"),p("Room: $140.00 per night<br/>Two-night subtotal: $280.00<br/>No payment has been processed."),
    h("Arrival notes"),p("Example check-in time: 16:00. Example check-out time: 11:00. Keep a copy of this confirmation with your travel documents."),
    h("Demo reservation"),p("This guesthouse and reservation are fictional. The document exists only to exercise PDF preview, download, and nested-folder browsing in Filey.")
])
document("Getting Started", "Welcome to your Filey sample drive", [
    h("Explore"),p("Open Documents for a resume, a moving checklist, and two receipts. Photos contains landscape and portrait images. Travel has a two-page itinerary and a reservation inside a nested folder."),
    h("Preview a file"),p("Tap a PDF or photo. Filey requests a temporary signed download URL, downloads a local copy, and opens the system preview. Larger photos make the row's loading spinner easier to see."),
    h("Try the empty state"),p("Inbox starts empty. Open it to check how the browser handles a folder with no files."),
    h("About this content"),p("All document names, people, businesses, purchases, and reservations are fictional. Photos are real CC0 photographs; their authors and source pages are recorded in the repository's seed-assets README."),
    h("Practice ideas"),p("Navigate several folders deep, return to the root, and open both portrait and landscape images. Open the itinerary and scroll to page two. Try previewing with the network disconnected, then retry after reconnecting.")
])
print("Generated seven PDF fixtures.")
