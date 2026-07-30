-- This filename deliberately sorts after the copied BBG governor scripts.
-- Civ6 loads files within one UpdateDatabase action by path, not modinfo listing order.
UPDATE Governors
SET TransitionStrength = 150
WHERE GovernorType IN (
    'GOVERNOR_THE_AMBASSADOR',
    'GOVERNOR_THE_CARDINAL',
    'GOVERNOR_THE_RESOURCE_MANAGER',
    'GOVERNOR_THE_BUILDER',
    'GOVERNOR_THE_EDUCATOR',
    'GOVERNOR_THE_MERCHANT',
    'GOVERNOR_THE_DEFENDER',
    'GOVERNOR_IBRAHIM'
);
