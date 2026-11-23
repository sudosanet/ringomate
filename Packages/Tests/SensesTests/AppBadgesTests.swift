@testable import Senses
import Testing

@Test func badgeLabelsSplitPerApp() {
    let output = """
    [ NULL ]  ASN:0x0-0x6e8ce86:
        bundleID=[ NULL ]
        "StatusLabel"={ "label"="3" }
     !cgsConnection !signalled type=[ NULL ]  Arch=!!none

    [ NULL ]  ASN:0x0-0x6ed3ecd:
        bundleID=[ NULL ]
     !cgsConnection !signalled type=[ NULL ]  Arch=!!none

    [ NULL ]  ASN:0x0-0x1:
        "StatusLabel"={ "label"="•" }

    """
    let labels = AppBadges.labels(output)
    #expect(labels.count == 3)
    #expect(labels["ASN:0x0-0x6e8ce86"] == .some(3))
    #expect(labels["ASN:0x0-0x6ed3ecd"] == .some(nil))
    #expect(labels["ASN:0x0-0x1"] == .some(1))
    #expect(labels["ASN:0x0-0x2"] == nil)
}
