A normal interaction would work like this:

Customer submits a title and initial description.
Create the ticket.
Store the description as the first public message.
Add a ticket_created event.
Route the ticket to a team.
Assign an agent and change the ticket to open.
Customer and agent replies become additional messages.
Internal support discussions become internal_note messages.
Resolving or reopening updates the ticket and creates corresponding events.