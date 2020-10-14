



package v1alpha1_test

import (
	"context"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	. "github.com/infobloxopen/konk/test/apiserver/pkg/apis/example/v1alpha1"
	. "github.com/infobloxopen/konk/test/apiserver/pkg/client/clientset_generated/clientset/typed/example/v1alpha1"
)

var _ = Describe("Contact", func() {
	var instance Contact
	var expected Contact
	var client ContactInterface

	BeforeEach(func() {
		instance = Contact{}
		instance.Name = "instance-1"

		expected = instance
	})

	AfterEach(func() {
		client.Delete(context.TODO(), instance.Name, metav1.DeleteOptions{})
	})

	Describe("when sending a storage request", func() {
		Context("for a valid config", func() {
			It("should provide CRUD access to the object", func() {
				client = cs.ExampleV1alpha1().Contacts("contact-test-valid")

				By("returning success from the create request")
				actual, err := client.Create(context.TODO(), &instance, metav1.CreateOptions{})
				Expect(err).ShouldNot(HaveOccurred())

				By("defaulting the expected fields")
				Expect(actual.Spec).To(Equal(expected.Spec))

				By("returning the item for list requests")
				result, err := client.List(context.TODO(), metav1.ListOptions{})
				Expect(err).ShouldNot(HaveOccurred())
				Expect(result.Items).To(HaveLen(1))
				Expect(result.Items[0].Spec).To(Equal(expected.Spec))

				By("returning the item for get requests")
				actual, err = client.Get(context.TODO(), instance.Name, metav1.GetOptions{})
				Expect(err).ShouldNot(HaveOccurred())
				Expect(actual.Spec).To(Equal(expected.Spec))

				By("deleting the item for delete requests")
				err = client.Delete(context.TODO(), instance.Name, metav1.DeleteOptions{})
				Expect(err).ShouldNot(HaveOccurred())
				result, err = client.List(context.TODO(), metav1.ListOptions{})
				Expect(err).ShouldNot(HaveOccurred())
				Expect(result.Items).To(HaveLen(0))
			})
		})
	})
})
